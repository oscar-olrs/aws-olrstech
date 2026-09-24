"""Restricted asynchronous directory searches and shared-mailbox delegation."""
import base64
import json
import os
import re
import uuid
from datetime import datetime, timezone

ADDRESSES = [name + '@olrstech.com' for name in ('it', 'hr', 'safety', 'sales', 'payroll')]


def allowed(user):
    if 'manage_mailboxes' not in user['permissions']:
        return []
    return ADDRESSES[:] if user['role'] == 'super' else [m for m in user.get('allowedMailboxes', []) if m in ADDRESSES]


def selections(app, user, data):
    value = data.get('mailboxAccess', [])
    if not isinstance(value, list) or len(value) > 5:
        raise app.Problem(400, 'Invalid mailbox selection.')
    result, seen = [], set()
    for entry in value:
        if not isinstance(entry, dict) or set(entry) != {'address', 'sendOnBehalf'}:
            raise app.Problem(400, 'Invalid mailbox selection.')
        address = entry['address']
        if not isinstance(address, str) or address not in ADDRESSES or address in seen or type(entry['sendOnBehalf']) is not bool:
            raise app.Problem(400, 'Invalid mailbox selection.')
        if address not in allowed(user):
            raise app.Problem(403, 'You cannot manage access to this mailbox.')
        seen.add(address)
        result.append({'address': address, 'sendOnBehalf': entry['sendOnBehalf']})
    return sorted(result, key=lambda e: e['address'])


def save(app, job, **values):
    values['updated'] = app.now()
    names, attrs, expressions = {}, {}, []
    for i, (key, value) in enumerate(values.items()):
        names[f'#k{i}'] = key
        attrs[f':v{i}'] = value
        expressions.append(f'#k{i} = :v{i}')
    app.TABLE.update_item(Key={'pk': job['pk']}, UpdateExpression='SET ' + ', '.join(expressions),
                          ExpressionAttributeNames=names, ExpressionAttributeValues=attrs)


def create_job(app, user, operation, **data):
    jid = str(uuid.uuid4())
    job = {'pk': 'mailboxjob#' + jid, 'id': jid, 'kind': 'mailboxjob', 'created': app.now(),
           'updated': app.now(), 'owner': user['sub'], 'operation': operation,
           'status': 'Queued', 'message': 'Waiting for the Windows server.', **data}
    app.TABLE.put_item(Item=job, ConditionExpression='attribute_not_exists(pk)')
    return job


def public(job, user):
    result = {k: job[k] for k in ('id', 'status', 'message', 'updated', 'operation')}
    if 'result' in job:
        result['result'] = job['result']
        if isinstance(result['result'], dict) and 'access' in result['result']:
            result['result'] = {**result['result'], 'access': [e for e in result['result']['access'] if e['address'] in allowed(user)], 'managed': [e for e in result['result'].get('managed', []) if e['address'] in allowed(user)]}
    return result


def api(app, user, method, path, event):
    if path == '/mailboxes' and method == 'GET':
        return app.reply(200, {'mailboxes': allowed(user), 'enabled': os.environ.get('MAILBOX_ENABLED') == 'true'})
    if not (path == '/users/search' or path.startswith('/mailbox-jobs/') or path in ('/users/access', '/users/profile')):
        return None
    if path in ('/users/access', '/users/profile'):
        app.require(user, 'manage_mailboxes' if path == '/users/access' else 'manage_users')
    elif not any(p in user['permissions'] for p in ('manage_users', 'manage_mailboxes')):
        raise app.Problem(403, 'You cannot manage employees.')
    if os.environ.get('MAILBOX_ENABLED') != 'true':
        raise app.Problem(409, 'Mailbox management is not connected yet.')
    if path.startswith('/mailbox-jobs/') and method == 'GET':
        job = app.TABLE.get_item(Key={'pk': 'mailboxjob#' + path.rsplit('/', 1)[-1]}, ConsistentRead=True).get('Item')
        if not job or (job['owner'] != user['sub'] and user['role'] != 'super'):
            raise app.Problem(404, 'Task not found.')
        poll(app, [job])
        job = app.TABLE.get_item(Key={'pk': job['pk']}, ConsistentRead=True).get('Item', job)
        return app.reply(200, public(job, user))
    if path == '/users/search' and method == 'POST':
        data = app.body(event)
        browse = data.get('browse', False)
        if type(browse) is not bool:
            raise app.Problem(400, 'Invalid browse option.')
        cursor = app.text(data, 'cursor', required=False, limit=100)
        if any(ord(c) < 32 for c in cursor):
            raise app.Problem(400, 'Invalid directory cursor.')
        query = app.text(data, 'query', required=not browse, limit=80)
        if not browse and (len(query) < 2 or not re.fullmatch(r'[a-zA-Z0-9 @._-]+', query)):
            raise app.Problem(400, 'Search with at least two letters or numbers.')
        username = data.get('username', '')
        if username and (not isinstance(username, str) or not re.fullmatch(r'[a-zA-Z0-9][a-zA-Z0-9._-]{0,19}', username)):
            raise app.Problem(400, 'Invalid username.')
        job = create_job(app, user, 'Inspect' if username else ('List' if browse else 'Search'), query=query, username=username, cursor=cursor)
        poll(app, [job])
        job = app.TABLE.get_item(Key={'pk': job['pk']}, ConsistentRead=True).get('Item', job)
        return app.reply(202, public(job, user))
    if path == '/users/profile' and method == 'POST':
        data = app.body(event)
        changes = {key: app.text(data, key, required=key in ('firstName', 'lastName'), limit=100)
                   for key in ('firstName', 'lastName', 'department', 'jobTitle', 'managerEmail')}
        if changes['managerEmail'] and not re.fullmatch(r'[^\s@]+@[^\s@]+\.[^\s@]+', changes['managerEmail']):
            raise app.Problem(400, 'Invalid manager email.')
        inspection = app.TABLE.get_item(Key={'pk': 'mailboxjob#' + app.text(data, 'inspectionId', limit=36)}, ConsistentRead=True).get('Item')
        if not inspection or inspection['operation'] != 'Inspect' or inspection['status'] != 'Complete' or inspection['owner'] != user['sub'] or 'profile' not in inspection.get('result', {}):
            raise app.Problem(409, 'Select the employee and refresh their details first.')
        if (datetime.now(timezone.utc) - datetime.fromisoformat(inspection['updated'])).total_seconds() > 900:
            raise app.Problem(409, 'Employee details expired. Refresh them first.')
        if inspection['result']['profile'].get('protected'):
            raise app.Problem(403, 'This account is protected from portal editing.')
        job = create_job(app, user, 'UpdateProfile', username=inspection['username'], changes=changes,
                         expectedProfile=inspection['result']['profile'])
        app.audit(user, 'update_ad_employee', job['id'])
        poll(app, [job])
        job = app.TABLE.get_item(Key={'pk': job['pk']}, ConsistentRead=True).get('Item', job)
        return app.reply(202, public(job, user))
    if path == '/users/access' and method == 'POST':
        data = app.body(event)
        desired = selections(app, user, data)
        inspection = app.TABLE.get_item(Key={'pk': 'mailboxjob#' + app.text(data, 'inspectionId', limit=36)}, ConsistentRead=True).get('Item')
        if not inspection or inspection['operation'] != 'Inspect' or inspection['status'] != 'Complete' or inspection['owner'] != user['sub']:
            raise app.Problem(409, 'Locate the employee and refresh their permissions first.')
        if (datetime.now(timezone.utc) - datetime.fromisoformat(inspection['updated'])).total_seconds() > 900:
            raise app.Problem(409, 'The permission view expired. Refresh it first.')
        username = inspection['username']
        previous = app.TABLE.get_item(Key={'pk': 'mailboxuser#' + username}, ConsistentRead=True).get('Item', {})
        # Administrators must not change mailboxes outside their assigned scope.
        baseline = previous.get('managed', [])
        preserved = [{'address': e['address'], 'sendOnBehalf': e['sendOnBehalf']} for e in baseline if e['address'] not in allowed(user)]
        desired = sorted(desired + preserved, key=lambda e: e['address'])
        # A reviewed edit may also change existing direct Exchange grants in this
        # administrator's allowed mailboxes. Inherited/group grants are untouched.
        inspected = inspection['result']['access']
        baseline = [e for e in baseline if e['address'] not in allowed(user)] + [
            {'address': e['address'], 'fullAccess': e['fullAccess'], 'sendOnBehalf': e['sendOnBehalf']}
            for e in inspected if e['address'] in allowed(user) and (e['fullAccess'] or e['sendOnBehalf'])]
        jid = str(uuid.uuid4())
        try:
            app.TABLE.update_item(Key={'pk': 'mailboxuser#' + username}, UpdateExpression='SET activeJob = :j',
                ConditionExpression='attribute_not_exists(activeJob)', ExpressionAttributeValues={':j': jid})
        except app.ClientError as exc:
            if exc.response['Error']['Code'] == 'ConditionalCheckFailedException':
                raise app.Problem(409, 'This employee already has an access change in progress or awaiting IT review.')
            raise
        job = {'pk': 'mailboxjob#' + jid, 'id': jid, 'kind': 'mailboxjob', 'created': app.now(),
               'updated': app.now(), 'owner': user['sub'], 'operation': 'Apply', 'username': username,
               'status': 'Queued', 'message': 'Waiting to apply mailbox access.', 'desired': desired,
               'managed': baseline, 'expected': inspection['result']['access']}
        app.TABLE.put_item(Item=job, ConditionExpression='attribute_not_exists(pk)')
        app.audit(user, 'change_mailbox_access', jid)
        return app.reply(202, public(job, user))
    raise app.Problem(404, 'Not found.')


def onboarding_job(app, record):
    if not record.get('mailboxAccess') or record.get('mailboxJobId'):
        return
    # Deterministic identity makes recovery between writes safe.
    jid = record['id']
    username = record['employee']['username']
    job = {'pk': 'mailboxjob#' + jid, 'id': jid, 'kind': 'mailboxjob', 'created': app.now(),
           'updated': app.now(), 'owner': record['owner'], 'operation': 'Apply', 'username': username,
           'status': 'Queued', 'message': 'Waiting for the employee mailbox in Microsoft 365.',
           'desired': record['mailboxAccess'], 'managed': [], 'expected': [], 'requestId': jid}
    try:
        app.TABLE.update_item(Key={'pk': 'mailboxuser#' + username}, UpdateExpression='SET activeJob = :j',
            ConditionExpression='attribute_not_exists(activeJob) OR activeJob = :j', ExpressionAttributeValues={':j': jid})
        app.TABLE.put_item(Item=job, ConditionExpression='attribute_not_exists(pk)')
    except app.ClientError as exc:
        if exc.response['Error']['Code'] != 'ConditionalCheckFailedException':
            raise
        existing = app.TABLE.get_item(Key={'pk': job['pk']}, ConsistentRead=True).get('Item')
        if not existing:
            app.update(jid, 'Sync requested', 'Account created; mailbox access needs IT review.', mailboxStatus='Needs review')
            return
    app.update(jid, 'Sync requested', 'Account created. Waiting for mailbox readiness before applying selected access.', mailboxJobId=jid, mailboxStatus='Pending')


def finish(app, job, status, message, result=None):
    values = {'status': status, 'message': message}
    if result is not None:
        values['result'] = result
    save(app, job, **values)
    if job['operation'] == 'Apply' and status == 'Complete':
        app.TABLE.update_item(Key={'pk': 'mailboxuser#' + job['username']},
            UpdateExpression='SET managed = :m, updated = :u REMOVE activeJob',
            ConditionExpression='activeJob = :j',
            ExpressionAttributeValues={':m': result['managed'], ':u': app.now(), ':j': job['id']})
    if job.get('requestId'):
        app.update(job['requestId'], 'Sync requested', message,
                   mailboxStatus='Granted' if status == 'Complete' else status)


def poll(app, jobs=None):
    if os.environ.get('MAILBOX_ENABLED') != 'true':
        return
    for job in (app.items('mailboxjob') if jobs is None else jobs):
        try:
            age = (datetime.now(timezone.utc) - datetime.fromisoformat(job['updated'])).total_seconds()
            if job['status'] in ('Complete', 'Needs review'):
                continue
            if job['status'] in ('Dispatching', 'Finalizing'):
                if age > 180:
                    finish(app, job, 'Needs review', 'Dispatch is uncertain. IT must inspect Systems Manager before retrying.')
                continue
            if job['status'] in ('Queued', 'Waiting for mailbox'):
                if job['status'] == 'Waiting for mailbox' and age < 180:
                    continue
                if (datetime.now(timezone.utc) - datetime.fromisoformat(job['created'])).total_seconds() > 86400:
                    finish(app, job, 'Needs review', 'Mailbox is not ready after 24 hours. IT must verify the Microsoft 365 license and mailbox.')
                    continue
                try:
                    app.TABLE.update_item(Key={'pk': job['pk']}, UpdateExpression='SET #s = :d, updated = :u',
                        ConditionExpression='#s = :old', ExpressionAttributeNames={'#s': 'status'},
                        ExpressionAttributeValues={':d': 'Dispatching', ':old': job['status'], ':u': app.now()})
                except app.ClientError as exc:
                    if exc.response['Error']['Code'] == 'ConditionalCheckFailedException':
                        continue
                    raise
                managed = app.TABLE.get_item(Key={'pk': 'mailboxuser#' + job.get('username', '')}, ConsistentRead=True).get('Item', {}).get('managed', [])
                payload = {'jobId': job['id'], 'operation': job['operation'], 'username': job.get('username', ''),
                           'query': job.get('query', ''), 'cursor': job.get('cursor', ''), 'changes': job.get('changes', {}), 'expectedProfile': job.get('expectedProfile', {}), 'desired': job.get('desired', []),
                           'managed': job.get('managed', managed), 'expected': job.get('expected', [])}
                encoded = base64.b64encode(json.dumps(payload).encode()).decode()
                command = app.SSM.send_command(InstanceIds=[os.environ['INSTANCE_ID']],
                    DocumentName=os.environ['MAILBOX_DOCUMENT'], DocumentVersion=os.environ['MAILBOX_DOCUMENT_VERSION'],
                    Parameters={'Payload': [encoded]}, TimeoutSeconds=300,
                    Comment='OLRS mailbox task ' + job['id'])['Command']
                save(app, job, status='Running', message='Checking the employee and mailbox access.', commandId=command['CommandId'])
            elif job['status'] == 'Running':
                try:
                    invocation = app.SSM.get_command_invocation(CommandId=job['commandId'], InstanceId=os.environ['INSTANCE_ID'])
                except app.SSM.exceptions.InvocationDoesNotExist:
                    if age > 600:
                        finish(app, job, 'Needs review', 'Task status unavailable. IT must inspect Systems Manager.')
                    continue
                if invocation['Status'] == 'Success':
                    try:
                        app.TABLE.update_item(Key={'pk': job['pk']}, UpdateExpression='SET #s = :f, updated = :u', ConditionExpression='#s = :r', ExpressionAttributeNames={'#s': 'status'}, ExpressionAttributeValues={':f': 'Finalizing', ':r': 'Running', ':u': app.now()})
                    except app.ClientError as exc:
                        if exc.response['Error']['Code'] == 'ConditionalCheckFailedException':
                            continue
                        raise
                    lines = invocation.get('StandardOutputContent', '').splitlines()
                    results = [line[12:] for line in lines if line.startswith('OLRS_RESULT:')]
                    if len(results) != 1:
                        raise ValueError('Missing result')
                    result = json.loads(results[0])
                    if result['status'] == 'Waiting':
                        save(app, job, status='Waiting for mailbox', message='Waiting for Microsoft 365 mailbox readiness; no access changes made.')
                    else:
                        finish(app, job, 'Complete', 'Mailbox access verified.' if job['operation'] == 'Apply' else ('Employee details saved in AD. Microsoft 365 updates follow directory synchronization.' if job['operation'] == 'UpdateProfile' else 'Employee results ready.'), result)
                elif invocation['Status'] in ('Failed', 'Cancelled', 'TimedOut', 'Undeliverable', 'Terminated') or age > 1800:
                    finish(app, job, 'Needs review', 'Task did not complete safely. IT must inspect the server before retrying.')
        except Exception as exc:
            # Never include employee data or Exchange output in application logs.
            print(json.dumps({'event': 'mailbox_task_error', 'errorType': type(exc).__name__, 'jobId': job['id']}))
            finish(app, job, 'Needs review', 'Mailbox task needs IT review. No automatic retry will be attempted.')
