#!/usr/bin/env python3
"""Read back the addon mirror's access controls without retrieving secret values."""
import json
import subprocess

REPO = 'jkc-be/goldbook-addon'


def api(path):
    result = subprocess.run(['gh', 'api', f'repos/{REPO}/{path}'.rstrip('/')],
                            check=True, capture_output=True, text=True)
    return json.loads(result.stdout)


def main():
    collaborators = api('collaborators?per_page=100')
    assert [(person['login'], person['role_name']) for person in collaborators] == [('jkc-be', 'admin')], 'Unexpected collaborator'
    assert not api('invitations'), 'Review pending invitations'
    keys = api('keys')
    assert [(key['id'], key['title'], key['read_only']) for key in keys] == [
        (166701423, 'Mirror from public Goldbook', False),
    ], 'Unexpected deploy key'
    rules = {rule['name']: api(f"rulesets/{rule['id']}") for rule in api('rulesets')}
    writes = rules['Main mirror updates']
    assert writes['enforcement'] == 'active' and writes['target'] == 'branch'
    assert writes['conditions']['ref_name'] == {'include': ['refs/heads/main'], 'exclude': []}
    assert {(actor['actor_type'], actor['actor_id'], actor['bypass_mode']) for actor in writes['bypass_actors']} == {
        ('RepositoryRole', 5, 'always'), ('DeployKey', None, 'always'),
    }, 'Unexpected main branch bypass'
    restrictions = {rule['type']: rule for rule in writes['rules']}
    assert {'creation', 'update', 'pull_request'} <= restrictions.keys()
    assert restrictions['pull_request']['parameters']['require_code_owner_review'] is True
    assert restrictions['pull_request']['parameters']['required_approving_review_count'] >= 1
    history = rules['Protect main history']
    assert history['enforcement'] == 'active' and history['target'] == 'branch'
    assert history['conditions']['ref_name'] == {'include': ['refs/heads/main'], 'exclude': []}
    assert not history['bypass_actors']
    assert {'deletion', 'non_fast_forward'} <= {rule['type'] for rule in history['rules']}
    assert api('actions/permissions/workflow') == {
        'default_workflow_permissions': 'read', 'can_approve_pull_request_reviews': False,
    }
    assert api('actions/permissions/fork-pr-contributor-approval')['approval_policy'] == 'all_external_contributors'
    assert api('actions/secrets')['total_count'] == 0, 'Move repository secrets into protected environments'
    for name, secret_name in [('curseforge', 'CURSEFORGE_API_TOKEN'),
                              ('wowinterface', 'WOWINTERFACE_API_TOKEN')]:
        environment = api(f'environments/{name}')
        assert environment['can_admins_bypass'] is False
        reviewers = next(rule for rule in environment['protection_rules'] if rule['type'] == 'required_reviewers')
        assert [(entry['type'], entry['reviewer']['login']) for entry in reviewers['reviewers']] == [('User', 'jkc-be')]
        assert environment['deployment_branch_policy'] == {'protected_branches': False, 'custom_branch_policies': True}
        policies = api(f'environments/{name}/deployment-branch-policies')['branch_policies']
        assert [(policy['name'], policy['type']) for policy in policies] == [('main', 'branch')]
        secrets = api(f'environments/{name}/secrets')['secrets']
        assert [secret['name'] for secret in secrets] == [secret_name]
    repo = api('')
    assert repo['visibility'] == 'public' and repo['allow_auto_merge'] is False
    for setting in ('secret_scanning', 'secret_scanning_push_protection'):
        assert repo['security_and_analysis'][setting]['status'] == 'enabled'
    print('Verified: sole owner, one mirror key, protected main history, read-only CI defaults,')
    print('owner-approved main-only publishing secrets, no repository secrets, and secret scanning.')


if __name__ == '__main__':
    main()
