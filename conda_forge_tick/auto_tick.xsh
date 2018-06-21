"""Copyright (c) 2017, Anthony Scopatz"""
import copy
import json
import os
import time
import traceback

import datetime
import github3
import networkx as nx
from rever.tools import indir

from .git_utils import (get_repo, push_repo)
from .utils import convert_dict_to_nt

# TODO: move this back to the bot file as soon as the source issue is sorted
# https://travis-ci.org/regro/00-find-feedstocks/jobs/388387895#L1870
from .migrators import *
$MIGRATORS = [Version(), 
# Compiler()
]

def run(attrs, migrator, feedstock=None, protocol='ssh',
        pull_request=True, rerender=True, fork=True, gh=None,
        **kwargs):
    """For a given feedstock and migration run the migration

    Parameters
    ----------
    attrs: dict
        The node attributes
    migrator: Migrator instance
        The migrator to run on the feedstock
    feedstock : str, optional
        The feedstock to clone if None use $FEEDSTOCK
    protocol : str, optional
        The git protocol to use, defaults to ``ssh``
    pull_request : bool, optional
        If true issue pull request, defaults to true
    fork : bool
        If true create a fork, defaults to true
    gh : github3.GitHub instance, optional
        Object for communicating with GitHub, if None build from $USERNAME
        and $PASSWORD, defaults to None
    kwargs: dict
        The key word arguments to pass to the migrator

    Returns
    -------
    migrate_return: dict
        The migration return dict used for tracking finished migrations
    pr_json: str
        The PR json object for recreating the PR as needed

    """
    # get the repo
    migrator.attrs = attrs
    feedstock_dir, repo = get_repo(attrs, branch=migrator.remote_branch(),
                                   feedstock=feedstock,
                                   protocol=protocol,
                                   pull_request=pull_request, fork=fork, gh=gh)

    # migrate the `meta.yaml`
    recipe_dir = os.path.join(feedstock_dir, 'recipe')
    migrate_return = migrator.migrate(recipe_dir, attrs, **kwargs)
    if not migrate_return:
        print($PROJECT, attrs.get('bad'))
        rm -rf @(feedstock_dir)
        return False

    # rerender, maybe
    with indir(feedstock_dir), ${...}.swap(RAISE_SUBPROC_ERROR=False):
        git commit -am @(migrator.commit_message())
        if rerender:
            print('Rerendering the feedstock')
            conda smithy rerender -c auto

    # push up
    try:
        pr_json = push_repo(feedstock_dir, migrator.pr_body(), repo, migrator.pr_title(),
                  migrator.pr_head(), migrator.remote_branch())
    # This shouldn't happen too often any more since we won't double PR
    except github3.GitHubError as e:
        if e.msg != 'Validation Failed':
            raise
    # If we've gotten this far then the node is good
    attrs['bad'] = False
    print('Removing feedstock dir')
    rm -rf @(feedstock_dir)
    return migrate_return, pr_json


def main():
    # gx = nx.read_yaml('graph.yml')
    gx = nx.read_gpickle('graph.pkl')
    $REVER_DIR = './feedstocks/'
    $REVER_QUIET = True
    gh = github3.login($USERNAME, $PASSWORD)
    
    smithy_version = ![conda smithy --version].output.strip()
    pinning_version = json.loads(![conda list conda-forge-pinning --json].output.strip())[0]['version']
    # TODO: need to also capture pinning version, maybe it is in the graph?
    
    for migrator in $MIGRATORS:
        gx2 = copy.deepcopy(gx)
    
        # Prune graph to only things that need builds
        for node, attrs in gx.node.items():
            if migrator.filter(attrs):
                gx2.remove_node(node)
        $SUBGRAPH = gx2
        print('Total migrations for {}: {}'.format(migrator.__class__.__name__,
                                                   len(gx2.node)))
    
        for node, attrs in gx2.node.items():
            # Don't let travis timeout, break ahead of the timeout so we make certain
            # to write to the repo
            if time.time() - int($START_TIME) > int($TIMEOUT):
                break
            $PROJECT = attrs['feedstock_name']
            $NODE = node
            print('BOT IS MIGRATING', $PROJECT)
            try:
                # Don't bother running if we are at zero
                if gh.rate_limit()['resources']['core']['remaining'] == 0:
                    break
                rerender = (gx.nodes[node].get('smithy_version') != smithy_version or
                            gx.nodes[node].get('pinning_version') != pinning_version or
                            migrator.rerender)
                migrator_hash, pr_json = run(attrs=attrs, migrator=migrator, gh=gh,
                                    rerender=rerender, protocol='https',
                                    hash_type=attrs.get('hash_type', 'sha256'))

                converted_hash = convert_dict_to_nt(migrator_hash)
                gx.nodes[node].setdefault('PRed', set()).update(converted_hash)
                # Stash the pr json data so we can access it later
                gx.nodes[node].setdefault('PRed_json', {}).update(
                    {converted_hash: pr_json})
                gx.nodes[node].update({'smithy_version': smithy_version,
                                       'pinning_version': pinning_version})
            except github3.GitHubError as e:
                print('GITHUB ERROR ON FEEDSTOCK: {}'.format($PROJECT))
                print(e)
                print(e.response)
                # carve out for PRs already submitted
                if e.msg == 'Repository was archived so is read-only.':
                    gx.nodes[node]['archived'] = True
                c = gh.rate_limit()['resources']['core']
                if c['remaining'] == 0:
                    ts = c['reset']
                    print('API timeout, API returns at')
                    print(datetime.datetime.utcfromtimestamp(ts)
                          .strftime('%Y-%m-%dT%H:%M:%SZ'))
                    break
            except Exception as e:
                print('NON GITHUB ERROR')
                print(e)
                with open('exceptions.md', 'a') as f:
                    f.write('#{name}\n\n##{exception}\n\n```python{tb}```\n\n'.format(
                        name=$PROJECT, exception=str(e),
                        tb=str(traceback.format_exc())))
            finally:
                # Write graph partially through
                # Race condition?
                # nx.write_yaml(gx, 'graph.yml')
                nx.write_gpickle(gx, 'graph.pkl')
                rm -rf $REVER_DIR + '/*'
                print(![pwd])
                ![doctr deploy --token --built-docs . --deploy-repo regro/cf-graph --deploy-branch-name master .]
    
    print('API Calls Remaining:', gh.rate_limit()['resources']['core']['remaining'])
    print('Done')
