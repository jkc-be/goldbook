#!/usr/bin/env python3
"""Configure or verify Goldbook's maintainer-controlled GitHub settings."""
import argparse
import json
import subprocess

REPO = 'jkc-be/goldbook'
OWNER_ID = 156444954
# Job names of the checks main requires, all reported by GitHub Actions (app 15368).
REQUIRED_CHECKS = ('test', 'local-stack', 'secrets', 'desktop-tests', 'changes')


def api(path, method='GET', data=None):
    command = ['gh', 'api', f'repos/{REPO}/{path}'.rstrip('/'), '--method', method]
    if data is not None:
        command += ['--input', '-']
    result = subprocess.run(command, input=json.dumps(data) if data is not None else None,
                            text=True, check=True, capture_output=True)
    return json.loads(result.stdout) if result.stdout.strip() else None


def settings():
    return {
        'main': {
            'name': 'main', 'target': 'branch', 'enforcement': 'active',
            'bypass_actors': [{'actor_id': 5, 'actor_type': 'RepositoryRole', 'bypass_mode': 'always'}],
            'conditions': {'ref_name': {'include': ['refs/heads/main'], 'exclude': []}},
            'rules': [
                {'type': 'creation'}, {'type': 'update'},
                {'type': 'pull_request', 'parameters': {
                    'required_approving_review_count': 1, 'dismiss_stale_reviews_on_push': True,
                    'require_code_owner_review': True, 'require_last_push_approval': False,
                    'required_review_thread_resolution': True,
                }},
                {'type': 'required_status_checks', 'parameters': {
                    'strict_required_status_checks_policy': True,
                    'required_status_checks': [{'context': name, 'integration_id': 15368}
                                               for name in REQUIRED_CHECKS],
                }},
            ],
        },
        'Protect main history': {
            'name': 'Protect main history', 'target': 'branch', 'enforcement': 'active',
            'bypass_actors': [],
            'conditions': {'ref_name': {'include': ['refs/heads/main'], 'exclude': []}},
            'rules': [{'type': 'deletion'}, {'type': 'non_fast_forward'}],
        },
    }


def configure():
    api('', 'PATCH', {'allow_auto_merge': False, 'delete_branch_on_merge': True,
                     'allow_update_branch': False, 'has_wiki': False,
                     'description': 'Goldbook desktop app, server, web UI and World of Warcraft addon. All rights reserved.'})
    existing = {rule['name']: rule['id'] for rule in api('rulesets')}
    for name, value in settings().items():
        path = f'rulesets/{existing[name]}' if name in existing else 'rulesets'
        api(path, 'PUT' if name in existing else 'POST', value)
    api('actions/permissions/workflow', 'PUT',
        {'default_workflow_permissions': 'read', 'can_approve_pull_request_reviews': False})
    api('actions/permissions/fork-pr-contributor-approval', 'PUT',
        {'approval_policy': 'all_external_contributors'})
    for environment in ('production', 'release-signing', 'addon-mirror'):
        path = f'environments/{environment}'
        api(path, 'PUT', {'wait_timer': 0, 'prevent_self_review': False, 'can_admins_bypass': False,
                         'reviewers': [{'type': 'User', 'id': OWNER_ID}],
                         'deployment_branch_policy': {'protected_branches': False,
                                                      'custom_branch_policies': True}})
        policies = api(path + '/deployment-branch-policies')['branch_policies']
        if not any(p['name'] == 'main' and p['type'] == 'branch' for p in policies):
            api(path + '/deployment-branch-policies', 'POST', {'name': 'main', 'type': 'branch'})
        for policy in policies:
            if policy['name'] != 'main' or policy['type'] != 'branch':
                api(path + '/deployment-branch-policies/' + str(policy['id']), 'DELETE')
    api('private-vulnerability-reporting', 'PUT')
    api('', 'PATCH', {'security_and_analysis': {
        'secret_scanning': {'status': 'enabled'},
        'secret_scanning_push_protection': {'status': 'enabled'},
    }})


def verify():
    collaborators = api('collaborators')
    admins = [person['login'] for person in collaborators if person['permissions']['admin']]
    assert admins == ['jkc-be'], f'Unexpected administrators: {admins}'
    assert not api('keys'), 'Review deploy keys: none are expected in the public repository'
    rules = {rule['name']: api(f"rulesets/{rule['id']}") for rule in api('rulesets')}
    required = {(check['context'], check['integration_id']) for rule in rules['main']['rules']
                if rule['type'] == 'required_status_checks'
                for check in rule['parameters']['required_status_checks']}
    missing = [name for name in REQUIRED_CHECKS if (name, 15368) not in required]
    assert not missing, f'main does not require these GitHub Actions checks: {missing}'
    for name, expected in settings().items():
        actual = rules[name]
        for field in ('enforcement', 'target', 'conditions', 'bypass_actors'):
            assert actual[field] == expected[field], (name, field)
        actual_rules = {rule['type']: rule for rule in actual['rules']}
        for rule in expected['rules']:
            assert rule['type'] in actual_rules, (name, rule['type'])
            for key, value in rule.get('parameters', {}).items():
                assert actual_rules[rule['type']]['parameters'][key] == value, (name, key)
    assert api('actions/permissions/workflow') == {
        'default_workflow_permissions': 'read', 'can_approve_pull_request_reviews': False}
    assert api('actions/permissions/fork-pr-contributor-approval')['approval_policy'] == 'all_external_contributors'
    assert api('actions/secrets')['total_count'] == 0, 'Use protected environment secrets, not repository secrets'
    for environment in ('production', 'release-signing', 'addon-mirror'):
        path = f'environments/{environment}'
        value = api(path)
        assert value['can_admins_bypass'] is False
        reviewers = next(rule for rule in value['protection_rules'] if rule['type'] == 'required_reviewers')
        assert [(r['type'], r['reviewer']['id']) for r in reviewers['reviewers']] == [('User', OWNER_ID)]
        assert reviewers['prevent_self_review'] is False
        assert value['deployment_branch_policy'] == {'protected_branches': False, 'custom_branch_policies': True}
        policies = api(path + '/deployment-branch-policies')['branch_policies']
        assert [(p['name'], p['type']) for p in policies] == [('main', 'branch')]
    repo = api('')
    assert repo['visibility'] == 'public' and repo['allow_auto_merge'] is False
    for name in ('secret_scanning', 'secret_scanning_push_protection'):
        assert repo['security_and_analysis'][name]['status'] == 'enabled'
    assert api('private-vulnerability-reporting')['enabled'] is True
    print('Verified sole administrator, main controls, protected environments, CI permissions and secret scanning.')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--check', action='store_true', help='Read settings without changing them')
    if not parser.parse_args().check:
        configure()
    verify()
