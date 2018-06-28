#!/usr/bin/env xonsh
import os
import time
cd ../cf-graph
$PATH.insert(0, '~/mc/bin')

stages = [3]
start = time.time()
for i in stages:
    conda-forge-tick --run @(i)
    print('FINISHED STAGE {} IN {} SECONDS'.format(i, time.time() - start))
    start = time.time()
doctr deploy --token --built-docs . --deploy-repo regro/cf-graph --deploy-branch-name master .
du -hs * | sort -hr
du -hs /tmp/* | sort -hr
for dir in g`/tmp/*`:
    if os.path.isdir(dir):
        du -hs @(os.path.join('/tmp', dir) + '/*') | sort -hr
