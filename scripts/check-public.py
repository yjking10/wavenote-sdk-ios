#!/usr/bin/env python3
"""Audit the exact staged files and all local commit history before publishing."""
import hashlib, pathlib, re, subprocess, sys
ROOT = pathlib.Path(__file__).resolve().parents[1]
# Explicit reviewed allowlist; additions require deliberate review.
ALLOWED = {'App/DemoController.swift', 'Core/DemoAudioLibrary.swift', 'Tests/IdentityHTTPTests.swift', 'Tests/DemoFlowTests.swift', 'App/SwiftIntegration.swift', 'Core/DemoFlow.swift', 'Tests/DemoAudioTests.swift', 'App/HTTPIdentityProvider.swift', 'WaveNoteDemo.xcodeproj/project.pbxproj', 'App/AppDelegate.swift', 'Core/DemoAudioStore.swift', 'scripts/run.sh', 'App/DemoNativePlayer.swift', 'App/ObjCIntegration.m', 'Core/IdentityHTTP.swift', 'README.md', 'scripts/check-public.py', 'WaveNoteDemo.xcodeproj/xcshareddata/xcschemes/WaveNoteDemo.xcscheme', 'scripts/verify.sh', 'scripts/prepare-sdk.sh', '.gitignore', 'App/Info.plist', 'Core/DemoOggPlayback.swift', 'Package.swift'}
WRAPPER_SHA256 = None
def git(*args):
    return subprocess.check_output(['git', '-C', str(ROOT), *args])
def fail(message):
    raise SystemExit('PUBLIC CHECK FAILED: ' + message)
def check(name, mode, data):
    if name not in ALLOWED: fail('unapproved path: ' + name)
    if mode not in ['100644', '100755']: fail('unsupported file mode: ' + name)
    if name == 'gradle/wrapper/gradle-wrapper.jar':
        if hashlib.sha256(data).hexdigest() != WRAPPER_SHA256: fail('Gradle wrapper checksum changed')
        return
    try: text = data.decode('utf-8')
    except UnicodeDecodeError: fail('unexpected binary: ' + name)
    forbidden = [
        r'/(?:Users|home)/[A-Za-z0-9_.-]+/',
        r'\b(?:192\.168|10\.\d+)\.\d+\.\d+\b',
        r'\bgh[pousr]_[A-Za-z0-9]{20,}\b',
        r'github_pat_[A-Za-z0-9_]{20,}',
        r'BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY',
        r'DEVELOPMENT_TEAM\s*=\s*(?!""\s*;)[A-Za-z0-9]+\s*;',
        r'yjking10/wavenote-sdk(?:\.git|/|[)\s])',
        'geili' + 'jiyao',
    ]
    if any(re.search(pattern, text) for pattern in forbidden): fail('private content pattern: ' + name)
    if name.endswith('.md'):
        for link in re.findall(r'(?<!!)\[[^\]]*\]\(([^)]+)\)', re.sub(r'```.*?```', '', text, flags=re.S)):
            target=link.split('#')[0].strip('<>')
            if not target or re.match(r'\w+://|mailto:',target):continue
            resolved=(ROOT/name).parent/target
            try: relative=str(resolved.resolve().relative_to(ROOT))
            except ValueError: fail('documentation link escapes repository: '+name)
            if relative not in ALLOWED:fail('link targets unpublished file: '+name)
# Index inspection ensures ignored files cannot be smuggled in with git add -f.
for row in git('ls-files', '--stage', '-z').decode().split('\0'):
    if not row: continue
    metadata,name=row.split('\t',1);mode,oid,stage=metadata.split()
    if stage != '0':fail('unmerged index: '+name)
    check(name,mode,git('cat-file','blob',oid))
for name in filter(None,git('ls-files','--others','--exclude-standard','-z').decode().split('\0')):
    if name not in ALLOWED:fail('unreviewed untracked file: '+name)
commits=git('rev-list','--all').decode().splitlines()
seen=set()
for commit in commits:
    for row in git('ls-tree','-r','-z',commit).decode().split('\0'):
        if not row:continue
        metadata,name=row.split('\t',1);mode,kind,oid=metadata.split()
        if (name,oid) in seen:continue
        seen.add((name,oid))
        if kind!='blob':fail('nested repository not allowed: '+name)
        check(name,mode,git('cat-file','blob',oid))
    for email in git('show','-s','--format=%ae%n%ce',commit).decode().splitlines():
        if not email.endswith('@users.noreply.github.com'):fail('commit contains non-noreply email')
print('PASS public file allowlist, staged blobs, links, wrapper checksum and full commit history')
