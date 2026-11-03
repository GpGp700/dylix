#!/usr/bin/env python3
"""Build a simulator app or unsigned device IPA with the embedded iOS toolchain."""
import argparse
import os
import pathlib
import plistlib
import shutil
import subprocess
import zipfile
import hashlib
import gzip

ROOT = pathlib.Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser()
parser.add_argument('--simulator', action='store_true')
parser.add_argument('--sdk-root', type=pathlib.Path, help='Real platform SDK used for compilation and linking (not the embedded tweak SDK)')
parser.add_argument('--identity', default='-')
parser.add_argument('--profile', type=pathlib.Path)
parser.add_argument('--share-profile', type=pathlib.Path, help='Provisioning profile for the Share Extension')
args = parser.parse_args()
platform = 'simulator' if args.simulator else 'device'
sdk = 'iphonesimulator' if args.simulator else 'iphoneos'
arch = 'x86_64' if args.simulator else 'arm64'
app = ROOT / 'build' / platform / 'TheosMobileCompiler.app'
if app.exists():
    shutil.rmtree(app)
app.mkdir(parents=True, exist_ok=True)
shutil.copyfile(ROOT / 'LICENSE', app / 'Dylix-LICENSE.txt')
frameworks = app / 'Frameworks'
frameworks.mkdir(exist_ok=True)
names = ['ios_system', 'libLLVM', 'clang', 'lld'] + ([] if args.simulator else ['perl'])
for name in names:
    bundle = pathlib.Path(os.environ.get('DYLIX_TOOLCHAIN_ROOT', str(ROOT))) / 'Vendor' / (name + '.xcframework')
    info = plistlib.loads((bundle / 'Info.plist').read_bytes())
    match = next(x for x in info['AvailableLibraries']
                 if x['SupportedPlatform'] == 'ios' and arch in x['SupportedArchitectures']
                 and x.get('SupportedPlatformVariant', '') == ('simulator' if args.simulator else ''))
    source = bundle / match['LibraryIdentifier'] / match['LibraryPath']
    dest = frameworks / source.name
    shutil.copytree(source, dest, dirs_exist_ok=True)
commands = {name: [f'{framework}.framework/{framework}', 'main', '', 'no']
            for name, framework in [('clang', 'clang'), ('ld64.lld', 'lld')]}
(app / 'commands.plist').write_bytes(plistlib.dumps(commands))
(app / 'commandDictionary.plist').write_bytes(plistlib.dumps({}))
(app / 'extraCommandsDictionary.plist').write_bytes(plistlib.dumps(commands))
# SDK archives are inert linker inputs, not code to sign. ldid mistakes a fat
# static archive for a fat executable and aborts with "Unknown header magic".
# Keep the complete SDK losslessly compressed, and materialize it in app caches.
for sdk_version, sdk_root, sdk_stem in [
    ('16.4', pathlib.Path(os.environ.get('DYLIX_SDK_16_4', str(ROOT / 'Resources/SDK'))), 'SDK'),
    ('26.0', pathlib.Path(os.environ.get('DYLIX_SDK_26_0', str(ROOT / 'LocalSDKs/iPhoneOS26.0.sdk'))), 'SDK26'),
]:
    metadata = plistlib.loads((sdk_root / 'SDKSettings.plist').read_bytes())
    if metadata.get('Version') != sdk_version:
        raise SystemExit('Embedded SDK metadata mismatch: ' + str(sdk_root))
    sdk_cache = ROOT / 'build' / ('embedded-' + sdk_stem + '.zip')
    if not sdk_cache.exists() or sdk_cache.stat().st_mtime < max(p.stat().st_mtime for p in sdk_root.rglob('*') if p.is_file()):
        sdk_temp = sdk_cache.with_name(sdk_cache.name + '.' + str(os.getpid()) + '.tmp')
        with zipfile.ZipFile(sdk_temp, 'w', zipfile.ZIP_DEFLATED) as archive:
            for path in sorted(sdk_root.rglob('*')):
                if path.is_file() and not any(part == '.DS_Store' or part == '__MACOSX' or part.startswith('._') for part in path.relative_to(sdk_root).parts):
                    archive.write(path, path.relative_to(sdk_root))
        sdk_temp.replace(sdk_cache)
    shutil.copyfile(sdk_cache, app / (sdk_stem + '.zip'))
    (app / (sdk_stem + 'Resource.plist')).write_bytes(plistlib.dumps({
        'version': sdk_version,
        'sha256': hashlib.sha256(sdk_cache.read_bytes()).hexdigest(),
    }))
resource_headers = ROOT / 'Resources/ClangInclude'
shutil.copytree(resource_headers, app / 'ClangInclude', dirs_exist_ok=True)
perl_config = (ROOT / 'Resources/Perl/Config.pm').read_text()
assert '$^V eq 5.34.0' in perl_config and "dlsrc => 'dl_none.xs'" in perl_config, 'Expected iOS Perl 5.34.0 modules'
resources = ['CompatibilityRules', 'ThirdPartyNotices', 'GitHelp', 'HelpArticles', 'Editor', 'GitDiff', 'RemoteWeb', 'logos', 'Include', 'Perl', 'SampleProject', 'SampleObjectiveC', 'SampleMultiProject', 'VendorFrameworks']
if args.simulator:
    resources.append('SampleLogosGenerated')
    resources.append('SampleMultiObjectiveC')
for resource in resources:
    shutil.copytree(ROOT / 'Resources' / resource, app / resource, dirs_exist_ok=True,
                    ignore=shutil.ignore_patterns('.git', '*.bundle', '*.dylib', '*.a', '*.o'))
# Arabic runtime translation table and native localization metadata.
shutil.copyfile(ROOT / 'Resources/Arabic.plist', app / 'Arabic.plist')
shutil.copytree(ROOT / 'Resources/ar.lproj', app / 'ar.lproj', dirs_exist_ok=True)
if args.profile:
    shutil.copy2(args.profile, app / 'embedded.mobileprovision')
# Precompressed offline editor assets reduce LAN transfer latency.
for asset in (app / 'RemoteWeb' / 'monaco').rglob('*'):
    if asset.suffix in ('.js', '.css') and asset.stat().st_size > 1024:
        asset.with_name(asset.name + '.gz').write_bytes(gzip.compress(asset.read_bytes(), compresslevel=6, mtime=0))

info = {
    'CFBundleExecutable': 'TheosMobileCompiler', 'CFBundleIdentifier': 'com.xuegao.theosmobilecompiler',
    'CFBundleName': 'Dylix', 'CFBundleDisplayName': 'Dylix',
    'CFBundleDevelopmentRegion': 'zh-Hans', 'CFBundleLocalizations': ['zh-Hans', 'en', 'ar'],
    'NSCameraUsageDescription': '拍摄照片作为您选择发送给模型的参考附件。', 'CFBundlePackageType': 'APPL', 'CFBundleShortVersionString': '1.0.7', 'CFBundleVersion': '160',
    'CFBundleDocumentTypes': [{'CFBundleTypeName':'Dylix Files','CFBundleTypeRole':'Editor','LSHandlerRank':'Alternate','LSItemContentTypes':['public.data','public.archive','public.source-code']}],
    'CFBundleURLTypes': [{'CFBundleURLName':'Dylix Incoming','CFBundleURLSchemes':['dylix', 'tweakforge']}],
    'BGTaskSchedulerPermittedIdentifiers': ['com.xuegao.theosmobilecompiler.ai.processing'],
    'UIBackgroundModes': ['processing', 'audio'],
    'NSSupportsLiveActivities': True,
    'MinimumOSVersion': '15.0', 'UIDeviceFamily': [1, 2],
    'NSAppTransportSecurity': {'NSAllowsLocalNetworking': True},
    'NSLocalNetworkUsageDescription': '在你开启局域网远程工作台或配置局域网 AI 服务时，允许同一 Wi-Fi 中经你配对的设备访问。',
    'UILaunchScreen': {}, 'UIFileSharingEnabled': True, 'LSSupportsOpeningDocumentsInPlace': True,
    'UISupportedInterfaceOrientations': ['UIInterfaceOrientationPortrait', 'UIInterfaceOrientationLandscapeLeft', 'UIInterfaceOrientationLandscapeRight'],
    'CFBundleSupportedPlatforms': ['iPhoneSimulator' if args.simulator else 'iPhoneOS'],
}
icon_info = ROOT / 'build' / platform / 'icons-info.plist'
asset_result = subprocess.run(['xcrun', 'actool', '--compile', str(app), '--platform', sdk,
                '--minimum-deployment-target', '15.0', '--app-icon', 'AppIcon',
                '--target-device', 'iphone', '--target-device', 'ipad',
                '--output-partial-info-plist', str(icon_info),
                str(ROOT / 'Resources/Assets.xcassets')])
if asset_result.returncode:
    previous_ipa = ROOT / 'build' / f"Dylix-1.0.5-build141-unsigned.ipa"
    catalog = ROOT / 'Resources/Assets.xcassets'
    newest_asset = max((p.stat().st_mtime for p in catalog.rglob('*') if p.is_file()), default=0)
    if not previous_ipa.exists() or previous_ipa.stat().st_mtime < newest_asset or not icon_info.exists():
        raise SystemExit('Asset catalog compilation failed and no current packaged assets are available')
    with zipfile.ZipFile(previous_ipa) as previous:
        (app / 'Assets.car').write_bytes(previous.read('Payload/TheosMobileCompiler.app/Assets.car'))
    print('actool failed; reused unchanged Assets.car from the previous IPA', flush=True)
info.update(plistlib.loads(icon_info.read_bytes()))
(app / 'Info.plist').write_bytes(plistlib.dumps(info))
sysroot = str(args.sdk_root.resolve()) if args.sdk_root else subprocess.check_output(['xcrun', '--sdk', sdk, '--show-sdk-path'], text=True).strip()
if args.simulator:
    # Disposable ARM64 fixture is data only, used by offline AI tool regression.
    fixture = ROOT / 'build' / 'classdump-fixture.dylib'
    subprocess.run(['xcrun', '--sdk', 'iphoneos', 'clang', '-arch', 'arm64', '-miphoneos-version-min=15.0', '-fobjc-arc', '-dynamiclib', '-Wl,-no_objc_category_merging', '-framework', 'Foundation', str(ROOT / 'tests/TFClassDumpFixture.m'), '-o', str(fixture)], check=True)
    with zipfile.ZipFile(app / 'AIClassDumpFixture.ipa', 'w', zipfile.ZIP_DEFLATED) as archive:
        archive.write(fixture, 'Payload/Fixture.app/Fixture')
settings_path = pathlib.Path(sysroot) / 'SDKSettings.json'
if settings_path.exists():
    import json
    sdk_settings = json.loads(settings_path.read_text())
else:
    sdk_settings = plistlib.loads((pathlib.Path(sysroot) / 'SDKSettings.plist').read_bytes())
sdk_version = sdk_settings['Version']
if args.sdk_root and sdk not in sdk_settings.get('SupportedTargets', {}):
    parser.error('SDK platform does not match build target: ' + sdk)
info['DTSDKName'] = sdk + sdk_version
info['DTPlatformVersion'] = sdk_version
(app / 'Info.plist').write_bytes(plistlib.dumps(info))
print('Build SDK: ' + sysroot + ' (' + sdk_version + ')', flush=True)
gitlib = ROOT / 'build' / ('git-' + platform) / 'libgit2.a'
if not gitlib.exists():
    subprocess.run(['python3', str(ROOT / 'scripts/build_git.py'), '--platform', platform], check=True)
classdumplib = ROOT / 'build' / ('classdump-' + platform) / 'libtweakforge_classdump.a'
subprocess.run(['python3', str(ROOT / 'scripts/build_classdump.py'), '--platform', platform], check=True)
cmd = ['xcrun', '--sdk', sdk, 'clang', '-arch', arch, '-isysroot', sysroot,
       '-mios-simulator-version-min=15.0' if args.simulator else '-miphoneos-version-min=15.0',
       '-fobjc-arc', '-fmodules', '-I' + str(ROOT / 'Vendor/libgit2/include'), '-framework', 'Network', '-framework', 'CoreImage', '-weak_framework', 'BackgroundTasks', '-framework', 'AVFoundation', '-framework', 'UserNotifications', '-framework', 'Security', '-framework', 'CoreFoundation', '-liconv', '-framework', 'UIKit', '-framework', 'CoreGraphics', '-framework', 'QuartzCore', '-framework', 'Foundation', '-framework', 'UniformTypeIdentifiers', '-framework', 'WebKit', '-framework', 'JavaScriptCore', '-larchive',
       '-F' + str(frameworks), '-framework', 'ios_system',
       '-Wl,-needed_framework,libLLVM',
       '-Wl,-rpath,@executable_path/Frameworks', str(ROOT / 'App/main.m'), str(ROOT / 'App/RuntimeDiagnostics.m'), str(ROOT / 'App/ArchiveImport.m'), str(ROOT / 'App/TheosMakefile.m'), str(ROOT / 'App/DebPackage.m'), str(ROOT / 'App/OutputNaming.m'), str(ROOT / 'App/CompatibilityRepair.m'), str(ROOT / 'App/Localization/TFLocalization.m'), str(ROOT / 'App/Studio.m'), str(ROOT / 'App/StorageSpace.m'), str(ROOT / 'App/ProjectSafety.m'), str(ROOT / 'App/ProjectTrash.m'), str(ROOT / 'App/GlassSupport.m'), str(ROOT / 'App/GitService.m'), str(ROOT / 'App/GitUI.m'), str(ROOT / 'App/GitHubRepositories.m'), str(ROOT / 'App/GitPATGuide.m'), str(ROOT / 'App/LinkSupport.m'), str(ROOT / 'App/HelpArticle.m'), str(ROOT / 'App/GitAutomation.m'), str(ROOT / 'App/GitDiffView.m'), str(gitlib), str(ROOT / 'Vendor/MBProgressHUD/MBProgressHUD.m'), '-o', str(app / 'TheosMobileCompiler')]
cmd.extend(str(p) for p in sorted((ROOT / 'App/AI').rglob('*.m')))
cmd.extend(str(p) for p in sorted((ROOT / 'App/Remote').glob('*.m')))
cmd.append(str(ROOT / 'App/SDKResources.m'))
cmd.extend(str(p) for p in sorted((ROOT / 'App/Incoming').glob('*.m')))
cmd.extend([str(classdumplib), '-framework', 'PhotosUI', '-framework', 'ImageIO'])
if args.sdk_root:
    # Xcode 16's module loader predates DarwinFoundation's SDK 26 module map.
    # Textual public headers work with this Objective-C app without SDK edits.
    cmd[cmd.index('-fmodules')] = '-fno-modules'
    subframeworks = pathlib.Path(sysroot) / 'System/Library/SubFrameworks'
    if subframeworks.exists():
        cmd.extend(['-F' + str(subframeworks)])
if args.simulator:
    # Simulator Security reads simulated iOS entitlements from this Mach-O section.
    # Keep the host macOS ad-hoc code signature free of restricted entitlements.
    simulated = ROOT / 'build' / 'simulator' / 'simulated-entitlements.plist'
    simulated.write_bytes(plistlib.dumps({
        'application-identifier': 'TMCLOCAL01.com.xuegao.theosmobilecompiler',
        'keychain-access-groups': ['TMCLOCAL01.com.xuegao.theosmobilecompiler'],
    }))
    cmd.extend(['-Xlinker', '-sectcreate', '-Xlinker', '__TEXT', '-Xlinker', '__entitlements', '-Xlinker', str(simulated)])
subprocess.run(cmd, check=True)
for name in names:
    subprocess.run(['codesign', '--force', '--sign', args.identity, str(frameworks / (name + '.framework'))], check=True)
# Share Extension passes copied files through an explicitly entitled App Group.
# Re-signing must preserve matching group rights in both provisioning profiles.
share = app / 'PlugIns/TweakForgeShare.appex'
share.mkdir(parents=True, exist_ok=True)
share_info = {
 'CFBundleExecutable':'TweakForgeShare','CFBundleIdentifier':'com.xuegao.theosmobilecompiler.share',
 'CFBundleName':'TweakForgeShare','CFBundleDisplayName':'Dylix','CFBundlePackageType':'XPC!',
 'CFBundleShortVersionString':'1.0.7','CFBundleVersion':info['CFBundleVersion'],
 'MinimumOSVersion':'15.0','UIDeviceFamily':[1,2],
 'CFBundleLocalizations':['zh-Hans','en','ar'],
 'CFBundleSupportedPlatforms':info['CFBundleSupportedPlatforms'],
 'NSExtension':{'NSExtensionPointIdentifier':'com.apple.share-services',
 'NSExtensionPrincipalClass':'ShareViewController',
 'NSExtensionAttributes':{'NSExtensionActivationRule':{'NSExtensionActivationSupportsFileWithMaxCount':20}}},
}
(share / 'Info.plist').write_bytes(plistlib.dumps(share_info))
shutil.copyfile(ROOT / 'Resources/Arabic.plist', share / 'Arabic.plist')
shutil.copytree(ROOT / 'Resources/ar.lproj', share / 'ar.lproj', dirs_exist_ok=True)
share_cmd=['xcrun','--sdk',sdk,'clang','-arch',arch,'-isysroot',sysroot,
 '-mios-simulator-version-min=15.0' if args.simulator else '-miphoneos-version-min=15.0',
 '-fobjc-arc','-fapplication-extension','-framework','UIKit','-framework','Foundation','-framework','UniformTypeIdentifiers',
 '-Wl,-e,_NSExtensionMain',str(ROOT / 'ShareExtension/ShareViewController.m'),str(ROOT / 'ShareExtension/TFShareLauncher.m'),str(ROOT / 'App/Incoming/TFShareTransfer.m'),str(ROOT / 'App/Incoming/TFShareGroups.m'),str(ROOT / 'App/Localization/TFLocalization.m'),'-o',str(share / 'TweakForgeShare')]
if args.sdk_root:
    share_cmd.append('-F' + str(pathlib.Path(sysroot) / 'System/Library/SubFrameworks'))
if args.share_profile:
    shutil.copy2(args.share_profile, share / 'embedded.mobileprovision')
subprocess.run(share_cmd,check=True)
share_entitlements=ROOT / 'build' / platform / 'share-entitlements.plist'
share_entitlements.write_bytes(plistlib.dumps({'com.apple.security.application-groups':['group.com.xuegao.tweakforge.share']}))
sign_flags=[] if args.simulator else ['--entitlements',str(share_entitlements)]
subprocess.run(['codesign','--force','--sign',args.identity,*sign_flags,str(share)],check=True)
subprocess.run(['python3',str(ROOT / 'scripts/build_live_activity.py'),'--app',str(app),'--build',info['CFBundleVersion'],'--identity',args.identity]+(['--simulator'] if args.simulator else []),check=True)
subprocess.run(['codesign','--force','--sign',args.identity,*sign_flags,str(app)],check=True)
if not args.simulator:
    ipa = ROOT / 'build' / f"Dylix-{info['CFBundleShortVersionString']}-build{info['CFBundleVersion']}-unsigned.ipa"
    with zipfile.ZipFile(ipa, 'w', zipfile.ZIP_DEFLATED) as out:
        for path in app.rglob('*'):
            if path.is_file(): out.write(path, pathlib.Path('Payload') / app.name / path.relative_to(app))
    print(ipa)
else:
    print(app)
