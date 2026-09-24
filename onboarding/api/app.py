"""OLRS onboarding API. Gateway verifies JWTs; permissions are checked here."""
import base64
import html
import json
import os
import re
import secrets
import string
import time
import uuid
import sys
import mailboxes
from datetime import datetime, timezone

import boto3
from boto3.dynamodb.conditions import Key
from botocore.exceptions import ClientError

TABLE = boto3.resource('dynamodb').Table(os.environ['TABLE_NAME'])
SSM = boto3.client('ssm')
COGNITO = boto3.client('cognito-idp')
SQS = boto3.client('sqs')
SECRETS = boto3.client('secretsmanager')
SES = boto3.client('sesv2')
PERMISSIONS = {'onboard', 'view_all', 'manage_admins', 'manage_mailboxes', 'manage_users'}
ROLES = {'hr': ['onboard'], 'it': ['onboard', 'view_all'],
         'super': sorted(PERMISSIONS)}


class Problem(Exception):
    def __init__(self, status, message):
        self.status, self.message = status, message


def now():
    return datetime.now(timezone.utc).isoformat()


def items(kind):
    result = []
    arguments = {'IndexName': 'by-kind', 'KeyConditionExpression': Key('kind').eq(kind)}
    while True:
        page = TABLE.query(**arguments)
        result.extend(page.get('Items', []))
        if not page.get('LastEvaluatedKey'):
            return result
        arguments['ExclusiveStartKey'] = page['LastEvaluatedKey']


def actor(event):
    claims = event.get('requestContext', {}).get('authorizer', {}).get('jwt', {}).get('claims', {})
    sub = claims.get('sub', '')
    # Require an access token for this client, rather than an ID token.
    if not sub or claims.get('token_use') != 'access' or claims.get('client_id') != os.environ['CLIENT_ID']:
        raise Problem(401, 'Please sign in again.')
    grant = TABLE.get_item(Key={'pk': 'admin#' + sub}, ConsistentRead=True).get('Item')
    if sub == os.environ.get('BOOTSTRAP_SUB') and sub:
        return {'sub': sub, 'email': os.environ.get('OWNER_EMAIL', ''),
                'permissions': sorted(PERMISSIONS), 'role': 'super'}
    if not grant or not grant.get('enabled', False):
        raise Problem(403, 'Your account does not have portal access.')
    return {'sub': sub, **grant}


def require(user, permission):
    if permission not in user['permissions']:
        raise Problem(403, 'You do not have permission for this action.')


def body(event):
    raw = event.get('body') or '{}'
    if event.get('isBase64Encoded'):
        raw = base64.b64decode(raw).decode('utf-8')
    if len(raw) > 8192:
        raise Problem(413, 'Request is too large.')
    try:
        data = json.loads(raw)
    except (ValueError, UnicodeError):
        raise Problem(400, 'Invalid request.')
    if not isinstance(data, dict):
        raise Problem(400, 'Invalid request.')
    return data


def text(data, name, required=True, limit=100):
    value = data.get(name, '')
    if not isinstance(value, str):
        raise Problem(400, f'Invalid {name}.')
    value = value.strip()
    if (required and not value) or len(value) > limit or any(ord(c) < 32 for c in value):
        raise Problem(400, f'Invalid {name}.')
    return value


def employee(data):
    result = {name: text(data, name) for name in ('firstName', 'lastName', 'username', 'department')}
    result.update({name: text(data, name, False) for name in ('jobTitle', 'managerEmail')})
    contact = text(data, 'contactEmail', False, 254).lower()
    if contact and not re.fullmatch(r'[^\s@]+@[^\s@]+\.[^\s@]+', contact):
        raise Problem(400, 'Enter a valid employee contact email.')
    if contact:
        result['contactEmail'] = contact
    result['username'] = result['username'].lower()
    # sAMAccountName length limit, no shell metacharacters or path components.
    if not re.fullmatch(r'[a-z][a-z0-9._-]{0,19}', result['username']):
        raise Problem(400, 'Username must start with a letter and contain at most 20 letters, numbers, dots, underscores or hyphens.')
    if result['managerEmail'] and not re.fullmatch(r'[^\s@]+@[^\s@]+\.[^\s@]+', result['managerEmail']):
        raise Problem(400, 'Enter a valid manager email.')
    return result


def reply(status, data):
    return {'statusCode': status, 'headers': {'Content-Type': 'application/json', 'Cache-Control': 'no-store'},
            'body': json.dumps(data, default=str)}


def audit(user, action, target):
    TABLE.put_item(Item={'pk': 'audit#' + str(uuid.uuid4()), 'kind': 'audit',
                         'created': now(), 'actor': user['sub'], 'action': action, 'target': target})


def public_request(item):
    return {key: item[key] for key in ('id', 'employee', 'created', 'updated', 'status', 'message', 'owner', 'mailboxAccess', 'mailboxStatus') if key in item}


def onboarding(user, data):
    require(user, 'onboard')
    if os.environ.get('PROVISIONING_ENABLED') != 'true':
        raise Problem(409, 'Provisioning is not connected yet. The PowerShell integration must be verified first.')
    record = employee(data)
    mailbox_access = mailboxes.selections(sys.modules[__name__], user, data)
    if mailbox_access and os.environ.get('MAILBOX_ENABLED') != 'true':
        raise Problem(409, 'Mailbox management is not connected yet.')
    rid = text(data, 'requestId', limit=36)
    try:
        if str(uuid.UUID(rid)) != rid:
            raise ValueError()
    except ValueError:
        raise Problem(400, 'Invalid request ID.')
    item = {'pk': 'request#' + rid, 'id': rid, 'kind': 'request', 'created': now(),
            'updated': now(), 'mailboxAccess': mailbox_access, 'employee': record, 'owner': user['sub'], 'status': 'Preparing',
            'message': 'Preparing secure onboarding credentials.',
            'notificationEligible': True, 'submitterEmail': user.get('email', ''),
            'notificationMailbox': 'onboarding@olrstech.com',
            'passwordSecret': os.environ.get('PASSWORD_PREFIX', 'olrs-onboarding-password-') + rid}
    newly_created = True
    # Persist before enqueue. Duplicate browser submissions return the same request.
    try:
        TABLE.put_item(Item=item, ConditionExpression='attribute_not_exists(pk)')
    except ClientError as exc:
        if exc.response['Error']['Code'] != 'ConditionalCheckFailedException':
            raise
        previous = TABLE.get_item(Key={'pk': item['pk']}, ConsistentRead=True)['Item']
        if previous['owner'] != user['sub'] or previous['employee'] != record or previous.get('mailboxAccess', []) != mailbox_access:
            raise Problem(409, 'This request ID is already in use.')
        item = previous
        newly_created = False
    if newly_created:
        alphabet = string.ascii_letters + string.digits + '!@#%_-+'
        password = 'Aa1!' + ''.join(secrets.choice(alphabet) for _ in range(28))
        try:
            SECRETS.create_secret(Name=item['passwordSecret'], ClientRequestToken=rid,
                                  SecretString=json.dumps({'password': password}),
                                  Tags=[{'Key': 'Project', 'Value': 'olrs'}])
        except Exception:
            update(rid, 'Blocked', 'Secure credential preparation failed. No command was sent.')
            raise
        finally:
            password = None
        update(rid, 'Queued', 'Waiting for the Windows server.')
        item['status'] = 'Queued'
        item['message'] = 'Waiting for the Windows server.'
    if item['status'] == 'Queued':
        SQS.send_message(QueueUrl=os.environ['QUEUE_URL'], MessageBody=json.dumps({'id': rid}))
    audit(user, 'submit_onboarding', rid)
    return reply(202, public_request(item))


def password_reveal(user, rid):
    require(user, 'onboard')
    item = TABLE.get_item(Key={'pk': 'request#' + rid}, ConsistentRead=True).get('Item')
    if not item or (item['owner'] != user['sub'] and 'manage_admins' not in user['permissions']):
        raise Problem(404, 'Request not found.')
    if item['status'] != 'Sync requested':
        raise Problem(409, 'The script must complete before the temporary password can be shown.')
    if (datetime.now(timezone.utc) - datetime.fromisoformat(item['created'])).total_seconds() > 86400:
        raise Problem(409, 'The password retrieval window expired. IT must reset the password securely.')
    try:
        TABLE.update_item(Key={'pk': item['pk']}, UpdateExpression='SET passwordRevealed = :r',
            ConditionExpression='attribute_not_exists(passwordRevealed)', ExpressionAttributeValues={':r': now()})
    except ClientError as exc:
        if exc.response['Error']['Code'] == 'ConditionalCheckFailedException':
            raise Problem(409, 'This password has already been shown. IT must reset it if needed.')
        raise
    password = json.loads(SECRETS.get_secret_value(SecretId=item['passwordSecret'])['SecretString'])['password']
    audit(user, 'reveal_temporary_password', rid)
    return reply(200, {'password': password})


def permissions(data):
    role = data.get('role', 'hr')
    if role not in ROLES:
        raise Problem(400, 'Choose a valid portal role.')
    values = data.get('permissions', ROLES[role])
    if not isinstance(values, list) or any(not isinstance(v, str) or v not in PERMISSIONS for v in values):
        raise Problem(400, 'Invalid portal permissions.')
    return role, sorted(set(values))


def admin_create(user, data):
    require(user, 'manage_admins')
    email = text(data, 'email', limit=254).lower()
    if not re.fullmatch(r'[^\s@]+@[^\s@]+\.[^\s@]+', email):
        raise Problem(400, 'Enter a valid administrator email.')
    role, perms = permissions(data)
    mailbox_scope = admin_mailboxes(data)
    try:
        account = COGNITO.admin_create_user(UserPoolId=os.environ['USER_POOL_ID'], Username=email,
                    UserAttributes=[{'Name': 'email', 'Value': email}], DesiredDeliveryMediums=['EMAIL'])['User']
    except COGNITO.exceptions.UsernameExistsException:
        account = COGNITO.admin_get_user(UserPoolId=os.environ['USER_POOL_ID'], Username=email)
    attrs = account.get('Attributes', account.get('UserAttributes', []))
    sub = next(a['Value'] for a in attrs if a['Name'] == 'sub')
    if sub == os.environ.get('BOOTSTRAP_SUB'):
        raise Problem(409, 'The owner account is protected.')
    item = {'pk': 'admin#' + sub, 'sub': sub, 'kind': 'admin', 'created': now(),
            'email': email, 'role': role, 'permissions': perms, 'enabled': True, 'allowedMailboxes': mailbox_scope}
    try:
        TABLE.put_item(Item=item, ConditionExpression='attribute_not_exists(pk)')
    except ClientError as exc:
        if exc.response['Error']['Code'] != 'ConditionalCheckFailedException':
            raise
        raise Problem(409, 'This administrator already has portal access. Edit their existing access.')
    audit(user, 'grant_admin_access', sub)
    return reply(201, item)


def admin_mailboxes(data):
    values = data.get('allowedMailboxes', [])
    if not isinstance(values, list) or any(not isinstance(v, str) or v not in mailboxes.ADDRESSES for v in values):
        raise Problem(400, 'Invalid administrator mailbox scope.')
    return sorted(set(values))


def api(event):
    user = actor(event)
    method = event['requestContext']['http']['method']
    path = event.get('rawPath', '')
    mailbox_reply = mailboxes.api(sys.modules[__name__], user, method, path, event)
    if mailbox_reply is not None:
        return mailbox_reply
    if method == 'GET' and path == '/me':
        return reply(200, {**user, 'provisioningEnabled': os.environ.get('PROVISIONING_ENABLED') == 'true', 'allowedMailboxes': mailboxes.allowed(user), 'mailboxEnabled': os.environ.get('MAILBOX_ENABLED') == 'true'})
    if path == '/requests' and method == 'POST':
        return onboarding(user, body(event))
    if path == '/requests' and method == 'GET':
        records = items('request')
        if 'view_all' not in user['permissions']:
            records = [r for r in records if r['owner'] == user['sub']]
        return reply(200, sorted([public_request(r) for r in records], key=lambda r: r['created'], reverse=True))
    if path.startswith('/requests/') and path.endswith('/password') and method == 'POST':
        return password_reveal(user, path.split('/')[2])
    if path == '/admins':
        require(user, 'manage_admins')
        if method == 'GET':
            return reply(200, items('admin'))
        if method == 'POST':
            return admin_create(user, body(event))
    if path.startswith('/admins/') and method == 'PATCH':
        require(user, 'manage_admins')
        sub = path.split('/')[-1]
        if sub in (user['sub'], os.environ.get('BOOTSTRAP_SUB')):
            raise Problem(409, 'Use another super admin to change your own access. The owner account is protected.')
        data = body(event)
        role, perms = permissions(data)
        enabled = data.get('enabled', True)
        if type(enabled) is not bool:
            raise Problem(400, 'Invalid enabled setting.')
        try:
            TABLE.update_item(Key={'pk': 'admin#' + sub},
                UpdateExpression='SET permissions = :p, #r = :r, enabled = :e, allowedMailboxes = :a',
                ExpressionAttributeNames={'#r': 'role'},
                ExpressionAttributeValues={':p': perms, ':r': role, ':e': enabled, ':a': admin_mailboxes(data)},
                ConditionExpression='attribute_exists(pk)')
        except ClientError as exc:
            if exc.response['Error']['Code'] == 'ConditionalCheckFailedException':
                raise Problem(404, 'Administrator not found.')
            raise
        audit(user, 'update_admin_access', sub)
        return reply(200, {'saved': True})
    raise Problem(404, 'Not found.')


def update(rid, status, message, **extra):
    values = {':s': status, ':m': message, ':u': now()}
    names = {'#s': 'status'}
    expression = 'SET #s = :s, message = :m, updated = :u'
    for index, (key, value) in enumerate(extra.items()):
        names[f'#x{index}'] = key
        values[f':x{index}'] = value
        expression += f', #x{index} = :x{index}'
    TABLE.update_item(Key={'pk': 'request#' + rid}, UpdateExpression=expression,
                       ExpressionAttributeNames=names, ExpressionAttributeValues=values)


def dispatch(rid):
    record = TABLE.get_item(Key={'pk': 'request#' + rid}, ConsistentRead=True).get('Item')
    if not record or record['status'] != 'Queued':
        return
    if os.environ.get('PROVISIONING_ENABLED') != 'true':
        update(rid, 'Blocked', 'Provisioning is disabled. No command was sent.')
        return
    # Lock before SendCommand. An ambiguous network result must never cause an automatic rerun.
    try:
        TABLE.update_item(Key={'pk': record['pk']},
            UpdateExpression='SET #s = :d, updated = :u',
            ConditionExpression='#s = :q', ExpressionAttributeNames={'#s': 'status'},
            ExpressionAttributeValues={':d': 'Dispatching', ':q': 'Queued', ':u': now()})
    except ClientError as exc:
        if exc.response['Error']['Code'] == 'ConditionalCheckFailedException':
            return
        raise
    payload = base64.b64encode(json.dumps({'requestId': rid, 'passwordSecret': record['passwordSecret'], **record['employee']}).encode()).decode()
    try:
        command = SSM.send_command(InstanceIds=[os.environ['INSTANCE_ID']],
                DocumentName=os.environ['DOCUMENT_NAME'], DocumentVersion=os.environ['DOCUMENT_VERSION'],
                Parameters={'Payload': [payload]}, TimeoutSeconds=300,
                Comment='OLRS onboarding ' + rid)['Command']
        update(rid, 'Running', 'Executing the verified onboarding script.', commandId=command['CommandId'])
    except Exception:
        update(rid, 'Needs review', 'Command dispatch could not be confirmed. IT must check Systems Manager before resubmitting.')
        raise


def notify_created(record):
    if os.environ.get('EMAIL_ENABLED') != 'true':
        return
    employee = record['employee']
    recipients = sorted(set(filter(None, [record.get('submitterEmail'), employee.get('contactEmail'), record.get('notificationMailbox')])))
    name = employee['firstName'] + ' ' + employee['lastName']
    email = employee['username'] + '@olrstech.com'
    from pathlib import Path
    template = (Path(__file__).parent / 'account-created.html').read_text()
    for recipient in recipients:
        # Claim each recipient before sending. Ambiguous sends require manual review.
        import hashlib
        key = 'mail#' + record['id'] + '#' + hashlib.sha256(recipient.encode()).hexdigest()
        try:
            TABLE.put_item(Item={'pk': key, 'kind': 'email', 'created': now(), 'status': 'Sending'},
                           ConditionExpression='attribute_not_exists(pk)')
        except ClientError as exc:
            if exc.response['Error']['Code'] == 'ConditionalCheckFailedException':
                continue
            raise
        values = {'logo_url': os.environ['SITE_URL'] + '/logo.png', 'recipient_name': 'there',
                  'employee_name': name, 'employee_email': email, 'department': employee['department']}
        rendered = template
        for field, value in values.items():
            rendered = rendered.replace('{{' + field + '}}', html.escape(value, quote=True))
        try:
            result = SES.send_email(FromEmailAddress='OLRS Tech Onboarding <' + os.environ['EMAIL_FROM'] + '>',
                Destination={'ToAddresses': [recipient]}, ReplyToAddresses=[os.environ['EMAIL_FROM']],
                Content={'Simple': {'Subject': {'Data': name + '’s account was created', 'Charset': 'UTF-8'},
                    'Body': {'Html': {'Data': rendered, 'Charset': 'UTF-8'},
                             'Text': {'Data': name + '’s employee account, ' + email + ', was created successfully. Microsoft 365 licensing and mailbox readiness require separate verification. Credentials are shared separately.', 'Charset': 'UTF-8'}}}})
            TABLE.update_item(Key={'pk': key}, UpdateExpression='SET #s = :s, messageId = :m',
                ExpressionAttributeNames={'#s': 'status'}, ExpressionAttributeValues={':s': 'Accepted', ':m': result['MessageId']})
        except Exception:
            TABLE.update_item(Key={'pk': key}, UpdateExpression='SET #s = :s',
                ExpressionAttributeNames={'#s': 'status'}, ExpressionAttributeValues={':s': 'Needs review'})
            print(json.dumps({'event': 'email_needs_review', 'requestId': record['id']}))


def poll():
    for record in items('request'):
        rid = record['id']
        age = (datetime.now(timezone.utc) - datetime.fromisoformat(record['updated'])).total_seconds()
        created_age = (datetime.now(timezone.utc) - datetime.fromisoformat(record['created'])).total_seconds()
        if record.get('passwordSecret') and created_age > 86400 and not record.get('passwordDeletionScheduled'):
            try:
                SECRETS.delete_secret(SecretId=record['passwordSecret'], RecoveryWindowInDays=7)
                TABLE.update_item(Key={'pk': record['pk']}, UpdateExpression='SET passwordDeletionScheduled = :t', ExpressionAttributeValues={':t': now()})
            except SECRETS.exceptions.ResourceNotFoundException:
                pass
        if record['status'] == 'Sync requested' and record.get('notificationEligible'):
            notify_created(record)
            mailboxes.onboarding_job(sys.modules[__name__], record)
        if record['status'] == 'Preparing':
            if age > 180:
                update(rid, 'Blocked', 'Credential preparation was interrupted. No command was sent.')
            continue
        if record['status'] == 'Queued':
            # Recover the persist/enqueue gap. Conditional dispatch lock prevents duplicates.
            if age > 120:
                SQS.send_message(QueueUrl=os.environ['QUEUE_URL'], MessageBody=json.dumps({'id': rid}))
            continue
        if record['status'] == 'Dispatching':
            if age > 180:
                update(rid, 'Needs review', 'Dispatch was interrupted. Check Systems Manager before resubmitting.')
            continue
        if record['status'] != 'Running':
            continue
        try:
            invocation = SSM.get_command_invocation(CommandId=record['commandId'], InstanceId=os.environ['INSTANCE_ID'])
        except SSM.exceptions.InvocationDoesNotExist:
            if age > 600:
                update(rid, 'Needs review', 'Command status is unavailable. Check Systems Manager.')
            continue
        status = invocation['Status']
        if status == 'Success':
            # Success means the script exited cleanly, never proof of M365 license/mailbox readiness.
            update(rid, 'Sync requested', 'The script completed. Microsoft 365 account, license and mailbox readiness are not yet verified.')
        elif status in ('Failed', 'Cancelled', 'TimedOut', 'Undeliverable', 'Terminated', 'DeliveryTimedOut', 'ExecutionTimedOut'):
            update(rid, 'Needs review', 'The onboarding command did not complete successfully. IT must inspect the server before resubmitting.')
        elif age > 1800:
            update(rid, 'Needs review', 'Command is taking longer than expected. IT must inspect Systems Manager.')


def handler(event, context):
    if event.get('source') == 'aws.events':
        poll()
        mailboxes.poll(sys.modules[__name__])
        return {'ok': True}
    if 'Records' in event:
        failures = []
        for message in event['Records']:
            try:
                dispatch(json.loads(message['body'])['id'])
            except Exception:
                failures.append({'itemIdentifier': message['messageId']})
        return {'batchItemFailures': failures}
    try:
        return api(event)
    except Problem as exc:
        return reply(exc.status, {'error': exc.message})
    except Exception as exc:
        # Do not log employee payloads, tokens, temporary passwords or command outputs.
        print(json.dumps({'errorType': type(exc).__name__, 'requestId': getattr(context, 'aws_request_id', '')}))
        return reply(500, {'error': 'The request could not be completed. Contact IT before retrying.'})
