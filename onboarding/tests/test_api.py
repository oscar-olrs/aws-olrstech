import importlib.util
import json
import os
from pathlib import Path
import sys
import types
import unittest
from unittest.mock import MagicMock, patch


class ClientError(Exception):
    def __init__(self, code):
        self.response = {'Error': {'Code': code}}


os.environ.update(TABLE_NAME='test', CLIENT_ID='client', BOOTSTRAP_SUB='owner',
                  OWNER_EMAIL='admin@olrstech.com', PROVISIONING_ENABLED='false',
                  QUEUE_URL='queue', INSTANCE_ID='instance', DOCUMENT_NAME='document',
                  DOCUMENT_VERSION='1', USER_POOL_ID='pool')
boto = types.ModuleType('boto3')
boto.resource = MagicMock()
boto.client = MagicMock()
conditions = types.ModuleType('boto3.dynamodb.conditions')
conditions.Key = MagicMock()
exceptions = types.ModuleType('botocore.exceptions')
exceptions.ClientError = ClientError
for name, module in {'boto3': boto, 'boto3.dynamodb': types.ModuleType('boto3.dynamodb'),
                     'boto3.dynamodb.conditions': conditions, 'botocore': types.ModuleType('botocore'),
                     'botocore.exceptions': exceptions}.items():
    sys.modules[name] = module
spec = importlib.util.spec_from_file_location('app', Path(__file__).parents[1] / 'api/app.py')
app = importlib.util.module_from_spec(spec)
sys.modules['app'] = app
spec.loader.exec_module(app)


def event(sub='hr', path='/me', method='GET', data=None, **claims):
    return {'rawPath': path, 'requestContext': {'http': {'method': method}, 'authorizer': {'jwt': {
        'claims': {'sub': sub, 'token_use': 'access', 'client_id': 'client', **claims}}}},
        'body': json.dumps(data or {})}


class SecurityTests(unittest.TestCase):
    def setUp(self):
        app.TABLE, app.SSM, app.SQS, app.COGNITO, app.SECRETS = (MagicMock() for _ in range(5))
        app.TABLE.get_item.return_value = {'Item': {'sub': 'hr', 'enabled': True,
            'permissions': ['onboard'], 'role': 'hr', 'email': 'hr@example.com'}}

    def call(self, e):
        return app.handler(e, None)

    def test_missing_claims_denied(self):
        self.assertEqual(self.call(event(sub=''))['statusCode'], 401)

    def test_id_token_and_wrong_client_denied(self):
        for claims in ({'token_use': 'id'}, {'client_id': 'other'}):
            self.assertEqual(self.call(event(**claims))['statusCode'], 401)

    def test_hr_cannot_manage_admins(self):
        for method in ('GET', 'POST'):
            self.assertEqual(self.call(event(path='/admins', method=method))['statusCode'], 403)
        app.COGNITO.admin_create_user.assert_not_called()

    def test_revoked_account_denied(self):
        app.TABLE.get_item.return_value['Item']['enabled'] = False
        self.assertEqual(self.call(event())['statusCode'], 403)

    def test_ungranted_account_denied(self):
        app.TABLE.get_item.return_value = {}
        self.assertEqual(self.call(event())['statusCode'], 403)

    def test_owner_does_not_require_database_grant(self):
        app.TABLE.get_item.return_value = {}
        result = self.call(event(sub='owner'))
        self.assertEqual(result['statusCode'], 200)
        self.assertIn('manage_admins', json.loads(result['body'])['permissions'])

    def test_owner_and_self_edits_protected(self):
        for target in ('owner',):
            self.assertEqual(self.call(event(sub='owner', path='/admins/'+target, method='PATCH'))['statusCode'], 409)
        app.TABLE.update_item.assert_not_called()

    def test_disabled_provisioning_cannot_enqueue(self):
        self.assertEqual(self.call(event(path='/requests', method='POST'))['statusCode'], 409)
        app.SQS.send_message.assert_not_called()
        app.SSM.send_command.assert_not_called()

    def test_hr_only_sees_own_requests(self):
        own = {'id': 'a', 'owner': 'hr', 'created': '2026-01-01'}
        other = {'id': 'b', 'owner': 'it', 'created': '2026-01-01'}
        with patch.object(app, 'items', return_value=[own, other]):
            records = json.loads(self.call(event(path='/requests'))['body'])
        self.assertEqual([r['id'] for r in records], ['a'])

    def test_bad_employee_username_rejected(self):
        for username in ("bad;whoami", '../admin', 'a'*21, '9user'):
            with self.assertRaises(app.Problem):
                app.employee({'firstName':'Jamie','lastName':'Rivera','username':username,'department':'IT'})

    def test_permission_names_allowlisted(self):
        for values in (['shell'], 'manage_admins', [1]):
            with self.assertRaises(app.Problem):
                app.permissions({'role':'hr','permissions':values})

    def test_dispatch_never_repeats_nonqueued_request(self):
        app.TABLE.get_item.return_value = {'Item': {'status': 'Dispatching'}}
        app.dispatch('id')
        app.SSM.send_command.assert_not_called()

    def test_ambiguous_dispatch_marked_for_review(self):
        record = {'pk': 'request#id', 'status':'Queued', 'employee': {'username':'jamie'}, 'passwordSecret':'secret'}
        app.TABLE.get_item.return_value = {'Item': record}
        app.SSM.send_command.side_effect = TimeoutError()
        with patch.dict(os.environ, PROVISIONING_ENABLED='true'), patch.object(app, 'update') as update:
            with self.assertRaises(TimeoutError):
                app.dispatch('id')
            self.assertEqual(update.call_args.args[1], 'Needs review')
        self.assertEqual(app.SSM.send_command.call_count, 1)

    def test_script_success_does_not_claim_m365_ready(self):
        record = {'id': 'id', 'status':'Running', 'created': app.now(), 'updated': app.now(), 'commandId':'command'}
        app.SSM.get_command_invocation.return_value = {'Status':'Success'}
        with patch.object(app, 'items', return_value=[record]), patch.object(app, 'update') as update:
            app.poll()
            self.assertEqual(update.call_args.args[1], 'Sync requested')
            self.assertIn('not yet verified', update.call_args.args[2])

    def test_it_view_all_does_not_allow_reading_another_password(self):
        record = {'owner':'other', 'status':'Sync requested', 'created':app.now(), 'passwordSecret':'secret'}
        app.TABLE.get_item.return_value = {'Item': record}
        with self.assertRaises(app.Problem) as error:
            app.password_reveal({'sub':'it','permissions':['onboard','view_all']}, 'id')
        self.assertEqual(error.exception.status, 404)
        app.SECRETS.get_secret_value.assert_not_called()

    def test_password_only_revealed_once_after_script_completes(self):
        record = {'pk':'request#id','owner':'hr', 'status':'Sync requested', 'created':app.now(), 'passwordSecret':'secret'}
        app.TABLE.get_item.return_value = {'Item': record}
        app.TABLE.update_item.side_effect = ClientError('ConditionalCheckFailedException')
        with self.assertRaises(app.Problem) as error:
            app.password_reveal({'sub':'hr','permissions':['onboard']}, 'id')
        self.assertEqual(error.exception.status, 409)
        app.SECRETS.get_secret_value.assert_not_called()

    def test_password_not_revealed_during_provisioning(self):
        app.TABLE.get_item.return_value = {'Item': {'owner':'hr','status':'Running'}}
        with self.assertRaises(app.Problem):
            app.password_reveal({'sub':'hr','permissions':['onboard']}, 'id')
        app.SECRETS.get_secret_value.assert_not_called()


class EmailTests(unittest.TestCase):
    def test_delivery_disabled(self):
        with patch.dict(os.environ, EMAIL_ENABLED='false'), patch.object(app, 'SES') as ses:
            app.notify_created({})
            ses.send_email.assert_not_called()

    def test_named_notice_escaped_and_scoped(self):
        record = {'id':'test', 'employee':{'firstName':'Chris <admin>', 'lastName':'Ronaldo', 'username':'cronaldo', 'department':'IT', 'contactEmail':'employee@example.com'}, 'submitterEmail':'admin@olrstech.com'}
        with patch.dict(os.environ, EMAIL_ENABLED='true', SITE_URL='https://onboarding.olrstech.com', EMAIL_FROM='onboarding@olrstech.com'), patch.object(app, 'TABLE') as table, patch.object(app, 'SES') as ses:
            ses.send_email.return_value = {'MessageId':'id'}
            app.notify_created(record)
            self.assertEqual(ses.send_email.call_count, 2)
            args = ses.send_email.call_args.kwargs
            self.assertEqual(args['ReplyToAddresses'], ['onboarding@olrstech.com'])
            rendered = args['Content']['Simple']['Body']['Html']['Data']
            self.assertIn('Chris &lt;admin&gt;', rendered)
            self.assertNotIn('{{', rendered)
            self.assertNotIn('passwordSecret', rendered)

    def test_shared_mailbox_copy_deduplicates_submitter(self):
        record = {'id':'test', 'employee':{'firstName':'Chris','lastName':'Ronaldo','username':'cronaldo','department':'IT'}, 'submitterEmail':'onboarding@olrstech.com', 'notificationMailbox':'onboarding@olrstech.com'}
        with patch.dict(os.environ, EMAIL_ENABLED='true', SITE_URL='https://onboarding.olrstech.com', EMAIL_FROM='onboarding@olrstech.com'), patch.object(app, 'TABLE'), patch.object(app, 'SES') as ses:
            ses.send_email.return_value = {'MessageId':'id'}
            app.notify_created(record)
            ses.send_email.assert_called_once()
            self.assertEqual(ses.send_email.call_args.kwargs['Destination']['ToAddresses'], ['onboarding@olrstech.com'])

    def test_duplicate_notice_not_sent(self):
        record = {'id':'test', 'employee':{'firstName':'Chris','lastName':'Ronaldo','username':'cronaldo','department':'IT'}, 'submitterEmail':'admin@olrstech.com'}
        with patch.dict(os.environ, EMAIL_ENABLED='true'), patch.object(app, 'TABLE') as table, patch.object(app, 'SES') as ses:
            table.put_item.side_effect = ClientError('ConditionalCheckFailedException')
            app.notify_created(record)
            ses.send_email.assert_not_called()

if __name__ == '__main__':
    unittest.main()
