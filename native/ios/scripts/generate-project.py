#!/usr/bin/env python3
"""Generate the small Xcode project without third-party project tooling."""
import hashlib
import plistlib
from pathlib import Path

root = Path(__file__).resolve().parents[1]
objects = {}
def add(key_name, isa, **fields):
    key = hashlib.sha1(key_name.encode()).hexdigest()[:24].upper()
    objects[key] = dict(isa=isa, **fields)
    return key

def file(path, kind):
    return add(path, 'PBXFileReference', lastKnownFileType=kind, path=path, sourceTree='<group>')
def build(ref):
    return add('build'+ref, 'PBXBuildFile', fileRef=ref)
def phase(name, isa, refs):
    return add(name, isa, buildActionMask=2147483647, files=[build(r) for r in refs], runOnlyForDeploymentPostprocessing=0)
def configs(name, settings):
    ids=[]
    for mode in ['Debug','Release']:
        merged=dict(settings)
        merged.update(SWIFT_OPTIMIZATION_LEVEL='-Onone' if mode=='Debug' else '-O',
                      SWIFT_ACTIVE_COMPILATION_CONDITIONS='DEBUG' if mode=='Debug' else '',
                      ENABLE_TESTABILITY='YES' if mode=='Debug' else 'NO',
                      DEBUG_INFORMATION_FORMAT='dwarf' if mode=='Debug' else 'dwarf-with-dsym')
        ids.append(add(name+mode, 'XCBuildConfiguration', name=mode, buildSettings=merged))
    return add(name+'configs', 'XCConfigurationList', buildConfigurations=ids, defaultConfigurationIsVisible=0, defaultConfigurationName='Release')

sources=[file(str(p.relative_to(root)), 'sourcecode.swift') for p in sorted((root/'WakeOn').glob('*.swift'))]
tests=[file(str(p.relative_to(root)), 'sourcecode.swift') for p in sorted((root/'Tests').glob('*.swift'))]
resources=[file('Resources/'+n, 'file') for n in ['encoder.onnx','decoder.onnx','joiner.onnx','tokens.txt','hey-lobby.txt','wake-fixture.wav']]
frameworks=[file('Vendor/build-ios-no-tts/'+p, 'wrapper.xcframework') for p in ['sherpa-onnx.xcframework','ios-onnxruntime/1.27.0/onnxruntime.xcframework']]
# WebRTC is a dynamic framework: link it and embed it in the app bundle.
webrtc=file('Vendor/WebRTC.xcframework', 'wrapper.xcframework')
frameworks.append(webrtc)
embed_file=add('embedWebRTC', 'PBXBuildFile', fileRef=webrtc, settings={'ATTRIBUTES': ['CodeSignOnCopy', 'RemoveHeadersOnCopy']})
embed=add('embedFrameworks', 'PBXCopyFilesBuildPhase', buildActionMask=2147483647, dstPath='', dstSubfolderSpec=10, files=[embed_file], name='Embed Frameworks', runOnlyForDeploymentPostprocessing=0)
app=add('product','PBXFileReference',explicitFileType='wrapper.application',path='WakeOn.app',sourceTree='BUILT_PRODUCTS_DIR',includeInIndex=0)
test_product=add('testproduct','PBXFileReference',explicitFileType='wrapper.cfbundle',path='WakeOnTests.xctest',sourceTree='BUILT_PRODUCTS_DIR',includeInIndex=0)
products=add('products','PBXGroup',children=[app,test_product],name='Products',sourceTree='<group>')
group=add('root','PBXGroup',children=sources+tests+resources+frameworks+[products],sourceTree='<group>')
common=dict(SWIFT_VERSION='5.0',IPHONEOS_DEPLOYMENT_TARGET='17.0',SDKROOT='iphoneos',SUPPORTED_PLATFORMS='iphoneos iphonesimulator',TARGETED_DEVICE_FAMILY='1,2',CLANG_ENABLE_MODULES='YES',CODE_SIGN_STYLE='Automatic')
appsettings=dict(common,PRODUCT_BUNDLE_IDENTIFIER='dev.wakeon.ios',PRODUCT_NAME='$(TARGET_NAME)',INFOPLIST_FILE='WakeOn/Info.plist',SWIFT_OBJC_BRIDGING_HEADER='WakeOn/Bridge.h',HEADER_SEARCH_PATHS='$(PROJECT_DIR)/Vendor/build-ios-no-tts/sherpa-onnx.xcframework/Headers',OTHER_LDFLAGS=['$(inherited)','-lc++'],LD_RUNPATH_SEARCH_PATHS=['$(inherited)','@executable_path/Frameworks'],ENABLE_USER_SCRIPT_SANDBOXING='YES')
app_target=add('app','PBXNativeTarget',name='WakeOn',productName='WakeOn',productReference=app,productType='com.apple.product-type.application',buildConfigurationList=configs('app',appsettings),buildPhases=[phase('sources','PBXSourcesBuildPhase',sources),phase('frameworks','PBXFrameworksBuildPhase',frameworks),phase('resources','PBXResourcesBuildPhase',resources),embed],buildRules=[],dependencies=[])
project_id=hashlib.sha1(b'project').hexdigest()[:24].upper()
proxy=add('proxy','PBXContainerItemProxy',containerPortal=project_id,proxyType=1,remoteGlobalIDString=app_target,remoteInfo='WakeOn')
dep=add('dependency','PBXTargetDependency',target=app_target,targetProxy=proxy)
test_settings=dict(common,PRODUCT_NAME='$(TARGET_NAME)',PRODUCT_BUNDLE_IDENTIFIER='dev.wakeon.ios.tests',GENERATE_INFOPLIST_FILE='YES',TEST_HOST='$(BUILT_PRODUCTS_DIR)/WakeOn.app/$(BUNDLE_EXECUTABLE_FOLDER_PATH)/WakeOn',BUNDLE_LOADER='$(TEST_HOST)',SWIFT_OBJC_BRIDGING_HEADER='WakeOn/Bridge.h',HEADER_SEARCH_PATHS=appsettings['HEADER_SEARCH_PATHS'])
test_target=add('tests','PBXNativeTarget',name='WakeOnTests',productName='WakeOnTests',productReference=test_product,productType='com.apple.product-type.bundle.unit-test',buildConfigurationList=configs('tests',test_settings),buildPhases=[phase('testSources','PBXSourcesBuildPhase',tests),phase('testFrameworks','PBXFrameworksBuildPhase',[])],buildRules=[],dependencies=[dep])
add('project','PBXProject',attributes={'LastUpgradeCheck':'2600'},buildConfigurationList=configs('project',common),compatibilityVersion='Xcode 14.0',developmentRegion='en',hasScannedForEncodings=0,knownRegions=['en','Base'],mainGroup=group,productRefGroup=products,projectDirPath='',projectRoot='',targets=[app_target,test_target])
proj=root/'WakeOn.xcodeproj'
proj.mkdir(exist_ok=True)
(proj/'project.pbxproj').write_bytes(plistlib.dumps(dict(archiveVersion='1',classes={},objectVersion='56',objects=objects,rootObject=project_id)))
scheme=proj/'xcshareddata/xcschemes'
scheme.mkdir(parents=True,exist_ok=True)
def ref(id,name):
    return f'<BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{id}" BuildableName="{name}" BlueprintName="{name.split(".")[0]}" ReferencedContainer="container:WakeOn.xcodeproj"/>'
(scheme/'WakeOn.xcscheme').write_text(f'''<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion="2600" version="1.3">
<BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES"><BuildActionEntries><BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="YES" buildForArchiving="YES" buildForAnalyzing="YES">{ref(app_target,'WakeOn.app')}</BuildActionEntry></BuildActionEntries></BuildAction>
<TestAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB"><Testables><TestableReference skipped="NO">{ref(test_target,'WakeOnTests.xctest')}</TestableReference></Testables></TestAction>
<LaunchAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" launchStyle="0" useCustomWorkingDirectory="NO" ignoresPersistentStateOnLaunch="NO" debugDocumentVersioning="YES" allowLocationSimulation="YES"><BuildableProductRunnable runnableDebuggingMode="0">{ref(app_target,'WakeOn.app')}</BuildableProductRunnable></LaunchAction>
<ProfileAction buildConfiguration="Release"><BuildableProductRunnable runnableDebuggingMode="0">{ref(app_target,'WakeOn.app')}</BuildableProductRunnable></ProfileAction>
<AnalyzeAction buildConfiguration="Debug"/><ArchiveAction buildConfiguration="Release" revealArchiveInOrganizer="YES"/>
</Scheme>''')
info=dict(CFBundleDevelopmentRegion='en',CFBundleExecutable='$(EXECUTABLE_NAME)',CFBundleIdentifier='$(PRODUCT_BUNDLE_IDENTIFIER)',CFBundleInfoDictionaryVersion='6.0',CFBundleName='Wake On',CFBundlePackageType='APPL',CFBundleShortVersionString='0.1.0',CFBundleVersion='2',LSRequiresIPhoneOS=True,NSMicrophoneUsageDescription='Listen locally for Hey Lobby, keep a short audio buffer for the wake handoff, and talk with the voice assistant.',UIBackgroundModes=['audio'],UILaunchScreen={},UISupportedInterfaceOrientations=['UIInterfaceOrientationPortrait','UIInterfaceOrientationLandscapeLeft','UIInterfaceOrientationLandscapeRight'],UIApplicationSceneManifest={'UIApplicationSupportsMultipleScenes':False},ITSAppUsesNonExemptEncryption=False,CFBundleURLTypes=[{'CFBundleURLName':'dev.wakeon.ios','CFBundleURLSchemes':['wakeon']}])
info['UISupportedInterfaceOrientations~ipad'] = info['UISupportedInterfaceOrientations'] + ['UIInterfaceOrientationPortraitUpsideDown']
(root/'WakeOn/Info.plist').write_bytes(plistlib.dumps(info))
