import json
import os
import unittest
from unittest.mock import MagicMock, patch
from test_api import app, event
import mailboxes


class MailboxTests(unittest.TestCase):
    def setUp(self):
        app.TABLE, app.SSM = MagicMock(), MagicMock()
        self.user = {'sub': 'it', 'role': 'it', 'permissions': ['onboard', 'manage_mailboxes'],
                     'allowedMailboxes': ['it@olrstech.com']}

    def test_no_implicit_mailbox_privilege(self):
        for role in ('hr', 'it'):
            self.assertEqual(mailboxes.allowed({'role': role, 'permissions': ['onboard']}), [])
        self.assertEqual(mailboxes.allowed({'role': 'super', 'permissions': ['manage_mailboxes']}), mailboxes.ADDRESSES)

    def test_payroll_denied_outside_administrator_scope(self):
        with self.assertRaises(app.Problem) as exc:
            mailboxes.selections(app, self.user, {'mailboxAccess': [{'address': 'payroll@olrstech.com', 'sendOnBehalf': False}]})
        self.assertEqual(exc.exception.status, 403)

    def test_untrusted_payload_and_duplicates_rejected(self):
        entry = {'address': 'it@olrstech.com', 'sendOnBehalf': False}
        for value in ('it', [entry, entry], [{**entry, 'sendOnBehalf': 'false'}], [{**entry, 'sendAs': True}], [{'address': 'other@olrstech.com', 'sendOnBehalf': False}]):
            with self.assertRaises(app.Problem):
                mailboxes.selections(app, self.user, {'mailboxAccess': value})

    def test_mailbox_job_cannot_be_read_by_another_admin(self):
        app.TABLE.get_item.return_value = {'Item': {'owner': 'other'}}
        with patch.dict(os.environ, MAILBOX_ENABLED='true'), self.assertRaises(app.Problem) as exc:
            mailboxes.api(app, self.user, 'GET', '/mailbox-jobs/123', {})
        self.assertEqual(exc.exception.status, 404)

    def test_inspection_required_before_mutation(self):
        app.TABLE.get_item.return_value = {}
        with patch.dict(os.environ, MAILBOX_ENABLED='true'), self.assertRaises(app.Problem):
            mailboxes.api(app, self.user, 'POST', '/users/access', event(data={'inspectionId': 'x'}))
        app.SSM.send_command.assert_not_called()
        app.TABLE.put_item.assert_not_called()

    def test_reviewed_existing_direct_access_can_be_removed(self):
        inspection = {'operation': 'Inspect', 'status': 'Complete', 'owner': 'it', 'updated': app.now(),
                      'username': 'chris', 'result': {'access': [{'address': 'it@olrstech.com', 'fullAccess': True, 'sendOnBehalf': False, 'externalFullAccess': True, 'externalSendOnBehalf': False}]}}
        app.TABLE.get_item.side_effect = [{'Item': inspection}, {}]
        with patch.dict(os.environ, MAILBOX_ENABLED='true'):
            response = mailboxes.api(app, self.user, 'POST', '/users/access', event(data={'inspectionId': 'x', 'mailboxAccess': []}))
        self.assertEqual(response['statusCode'], 202)
        saved = next(c.kwargs['Item'] for c in app.TABLE.put_item.call_args_list if c.kwargs['Item'].get('kind') == 'mailboxjob')
        self.assertEqual(saved['desired'], [])
        self.assertEqual(saved['managed'], [{'address': 'it@olrstech.com', 'fullAccess': True, 'sendOnBehalf': False}])

    def test_browse_without_query_is_supported(self):
        app.TABLE.get_item.return_value = {}
        with patch.dict(os.environ, MAILBOX_ENABLED='true'), patch.object(mailboxes, 'poll'):
            response = mailboxes.api(app, self.user, 'POST', '/users/search', event(data={'browse': True}))
        self.assertEqual(response['statusCode'], 202)
        self.assertEqual(app.TABLE.put_item.call_args.kwargs['Item']['operation'], 'List')

    def test_profile_edit_requires_separate_permission(self):
        with patch.dict(os.environ, MAILBOX_ENABLED='true'), self.assertRaises(app.Problem) as exc:
            mailboxes.api(app, self.user, 'POST', '/users/profile', event())
        self.assertEqual(exc.exception.status, 403)
        app.TABLE.put_item.assert_not_called()

    def test_waiting_mailbox_does_not_report_granted(self):
        job = {'pk': 'mailboxjob#id', 'id': 'id', 'operation': 'Apply', 'status': 'Running', 'updated': app.now(), 'commandId': 'command'}
        app.SSM.get_command_invocation.return_value = {'Status': 'Success', 'StandardOutputContent': 'OLRS_RESULT:{"status":"Waiting"}'}
        with patch.dict(os.environ, MAILBOX_ENABLED='true'), patch.object(app, 'items', return_value=[job]):
            mailboxes.poll(app)
        values = app.TABLE.update_item.call_args.kwargs['ExpressionAttributeValues']
        self.assertIn('Waiting for mailbox', values.values())
        app.SSM.send_command.assert_not_called()

    def test_running_and_complete_jobs_never_redispatched(self):
        for status in ('Complete', 'Needs review', 'Dispatching'):
            job = {'pk': 'mailboxjob#id', 'id': 'id', 'status': status, 'updated': app.now()}
            with patch.dict(os.environ, MAILBOX_ENABLED='true'), patch.object(app, 'items', return_value=[job]):
                mailboxes.poll(app)
        app.SSM.send_command.assert_not_called()

    def test_inspection_result_hides_unassigned_mailboxes(self):
        job = {'id': 'x', 'status': 'Complete', 'message': 'ok', 'updated': app.now(), 'operation': 'Inspect',
               'result': {'access': [{'address': 'it@olrstech.com'}, {'address': 'payroll@olrstech.com'}]}}
        self.assertEqual([e['address'] for e in mailboxes.public(job, self.user)['result']['access']], ['it@olrstech.com'])
