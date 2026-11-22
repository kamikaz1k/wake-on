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
def build(ref, prefix='build'):
    return add(prefix+ref, 'PBXBuildFile', fileRef=ref)
def phase(name, isa, refs, prefix='build'):
    # A file compiled into two targets needs a build file per target: give the second a prefix.
    return add(name, isa, buildActionMask=2147483647, files=[build(r, prefix) for r in refs], runOnlyForDeploymentPostprocessing=0)
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

sources=[file(str(p.relative_to(root)), 'sourcecode.swift') for p in sorted((root/'WakeOn').rglob('*.swift'))]
sources+=[file(str(p.relative_to(root)), 'sourcecode.metal') for p in sorted((root/'WakeOn').rglob('*.metal'))]
# Compiled into both the app and the Live Activity extension.
shared=[file(str(p.relative_to(root)), 'sourcecode.swift') for p in sorted((root/'Shared').glob('*.swift'))]
activity_sources=[file(str(p.relative_to(root)), 'sourcecode.swift') for p in sorted((root/'WakeOnLiveActivity').glob('*.swift'))]
activity_assets=file('WakeOnLiveActivity/Assets.xcassets', 'folder.assetcatalog')
tests=[file(str(p.relative_to(root)), 'sourcecode.swift') for p in sorted((root/'Tests').glob('*.swift'))]
resources=[file('Resources/'+n, 'file') for n in ['encoder.onnx','decoder.onnx','joiner.onnx','tokens.txt','hey-lobby.txt','wake-fixture.wav']]
# Recorded two-voice conversation for the visualizer gallery.
resources+=[file('WakeOn/Assets.xcassets', 'folder.assetcatalog')]
resources+=[file('WakeOn/PrivacyInfo.xcprivacy', 'text.xml')]
resources+=[file(str(p.relative_to(root)), 'audio.wav') for p in sorted((root/'Resources/VisualizerSamples').glob('*.wav'))]
frameworks=[file('Vendor/build-ios-no-tts/'+p, 'wrapper.xcframework') for p in ['sherpa-onnx.xcframework','ios-onnxruntime/1.27.0/onnxruntime.xcframework']]
# WebRTC is a dynamic framework: link it and embed it in the app bundle.
webrtc=file('Vendor/WebRTC.xcframework', 'wrapper.xcframework')
frameworks.append(webrtc)
embed_file=add('embedWebRTC', 'PBXBuildFile', fileRef=webrtc, settings={'ATTRIBUTES': ['CodeSignOnCopy', 'RemoveHeadersOnCopy']})
embed=add('embedFrameworks', 'PBXCopyFilesBuildPhase', buildActionMask=2147483647, dstPath='', dstSubfolderSpec=10, files=[embed_file], name='Embed Frameworks', runOnlyForDeploymentPostprocessing=0)
# The Live Activity (orb in the Dynamic Island) is a widget extension embedded in the app.
appex=add('appexproduct','PBXFileReference',explicitFileType='wrapper.app-extension',path='WakeOnLiveActivity.appex',sourceTree='BUILT_PRODUCTS_DIR',includeInIndex=0)
embed_appex_file=add('embedAppex', 'PBXBuildFile', fileRef=appex, settings={'ATTRIBUTES': ['RemoveHeadersOnCopy']})
embed_appex=add('embedAppExtensions', 'PBXCopyFilesBuildPhase', buildActionMask=2147483647, dstPath='', dstSubfolderSpec=13, files=[embed_appex_file], name='Embed Foundation Extensions', runOnlyForDeploymentPostprocessing=0)
app=add('product','PBXFileReference',explicitFileType='wrapper.application',path='WakeOn.app',sourceTree='BUILT_PRODUCTS_DIR',includeInIndex=0)
test_product=add('testproduct','PBXFileReference',explicitFileType='wrapper.cfbundle',path='WakeOnTests.xctest',sourceTree='BUILT_PRODUCTS_DIR',includeInIndex=0)
# Chat Lab: a separate app for comparing chat UI libraries (docs/research/chat-ui-scenarios.md).
# Kept out of Wake On so its packages never touch the voice app or its launch time.
lab_sources=[file(str(p.relative_to(root)), 'sourcecode.swift') for p in sorted((root/'ChatLab').glob('*.swift'))]
# Lobby's chat view, compiled into both Wake On (chat logs) and Chat Lab.
chat_ui=[file(str(p.relative_to(root)), 'sourcecode.swift') for p in sorted((root/'ChatUI').glob('*.swift'))]
# A made-up sample call in Wake On's capture format; real captures stay off git (captures/).
lab_resources=[file(str(p.relative_to(root)), 'text') for p in sorted((root/'ChatLab/Captures').glob('*.jsonl'))]
lab_app=add('labproduct','PBXFileReference',explicitFileType='wrapper.application',path='ChatLab.app',sourceTree='BUILT_PRODUCTS_DIR',includeInIndex=0)
lab_ui_sources=[file(str(p.relative_to(root)), 'sourcecode.swift') for p in sorted((root/'ChatLabUITests').glob('*.swift'))]
lab_ui_product=add('labuiproduct','PBXFileReference',explicitFileType='wrapper.cfbundle',path='ChatLabUITests.xctest',sourceTree='BUILT_PRODUCTS_DIR',includeInIndex=0)
lab_packages=[  # url, requirement, products
    ('https://github.com/exyte/Chat.git', dict(kind='upToNextMajorVersion', minimumVersion='3.3.7'), ['ExyteChat']),
    # MarkdownView stays on 3.x: LanguageModelChatUI 0.2 requires it.
    ('https://github.com/Lakr233/MarkdownView', dict(kind='upToNextMajorVersion', minimumVersion='3.7.0'), ['MarkdownView','MarkdownParser']),
    ('https://github.com/peterfriese/ConversationKit', dict(kind='upToNextMinorVersion', minimumVersion='0.1.1'), ['ConversationKit']),
    ('https://github.com/Lakr233/LanguageModelChatUI', dict(kind='upToNextMinorVersion', minimumVersion='0.2.0'), ['LanguageModelChatUI','ChatClientKit']),
]
lab_package_refs=[]
lab_product_deps=[]
for url, requirement, names in lab_packages:
    ref_id=add('pkg'+url,'XCRemoteSwiftPackageReference',repositoryURL=url,requirement=requirement)
    lab_package_refs.append(ref_id)
    for name in names:
        lab_product_deps.append(add('pkgproduct'+name,'XCSwiftPackageProductDependency',package=ref_id,productName=name))
lab_framework_files=[add('labbuild'+d,'PBXBuildFile',productRef=d) for d in lab_product_deps]
# Wake On uses only MarkdownView, for the chat view's Lobby text.
app_product_deps=[k for k in lab_product_deps if objects[k]['productName'] in ('MarkdownView','MarkdownParser')]
app_framework_files=[add('appbuild'+d,'PBXBuildFile',productRef=d) for d in app_product_deps]
products=add('products','PBXGroup',children=[app,test_product,appex,lab_app,lab_ui_product],name='Products',sourceTree='<group>')
group=add('root','PBXGroup',children=sources+shared+activity_sources+[activity_assets]+tests+resources+frameworks+chat_ui+lab_sources+lab_resources+lab_ui_sources+[products],sourceTree='<group>')
common=dict(SWIFT_VERSION='5.0',IPHONEOS_DEPLOYMENT_TARGET='17.0',SDKROOT='iphoneos',SUPPORTED_PLATFORMS='iphoneos iphonesimulator',TARGETED_DEVICE_FAMILY='1,2',CLANG_ENABLE_MODULES='YES',CODE_SIGN_STYLE='Automatic',DEVELOPMENT_TEAM='JDR6VAV2RA',CURRENT_PROJECT_VERSION='2')
appsettings=dict(common,ONLY_ACTIVE_ARCH='YES',PRODUCT_BUNDLE_IDENTIFIER='com.kamikaz1k.wakeon',PRODUCT_NAME='$(TARGET_NAME)',INFOPLIST_FILE='WakeOn/Info.plist',SWIFT_OBJC_BRIDGING_HEADER='WakeOn/Bridge.h',HEADER_SEARCH_PATHS='$(PROJECT_DIR)/Vendor/build-ios-no-tts/sherpa-onnx.xcframework/Headers',OTHER_LDFLAGS=['$(inherited)','-lc++'],LD_RUNPATH_SEARCH_PATHS=['$(inherited)','@executable_path/Frameworks'],ENABLE_USER_SCRIPT_SANDBOXING='YES',ASSETCATALOG_COMPILER_APPICON_NAME='AppIcon')
project_id=hashlib.sha1(b'project').hexdigest()[:24].upper()
activity_settings=dict(common,PRODUCT_BUNDLE_IDENTIFIER='com.kamikaz1k.wakeon.LiveActivity',PRODUCT_NAME='$(TARGET_NAME)',INFOPLIST_FILE='WakeOnLiveActivity/Info.plist',SKIP_INSTALL='YES',APPLICATION_EXTENSION_API_ONLY='YES',LD_RUNPATH_SEARCH_PATHS=['$(inherited)','@executable_path/Frameworks','@executable_path/../../Frameworks'])
activity_target=add('activity','PBXNativeTarget',name='WakeOnLiveActivity',productName='WakeOnLiveActivity',productReference=appex,productType='com.apple.product-type.app-extension',buildConfigurationList=configs('activity',activity_settings),buildPhases=[phase('activitySources','PBXSourcesBuildPhase',activity_sources+shared),phase('activityFrameworks','PBXFrameworksBuildPhase',[]),phase('activityResources','PBXResourcesBuildPhase',[activity_assets])],buildRules=[],dependencies=[])
activity_proxy=add('activityProxy','PBXContainerItemProxy',containerPortal=project_id,proxyType=1,remoteGlobalIDString=activity_target,remoteInfo='WakeOnLiveActivity')
activity_dep=add('activityDependency','PBXTargetDependency',target=activity_target,targetProxy=activity_proxy)
app_target=add('app','PBXNativeTarget',name='WakeOn',productName='WakeOn',productReference=app,productType='com.apple.product-type.application',buildConfigurationList=configs('app',appsettings),buildPhases=[phase('sources','PBXSourcesBuildPhase',sources+shared+chat_ui),add('frameworks','PBXFrameworksBuildPhase',buildActionMask=2147483647,files=[build(r) for r in frameworks]+app_framework_files,runOnlyForDeploymentPostprocessing=0),phase('resources','PBXResourcesBuildPhase',resources),embed,embed_appex],buildRules=[],dependencies=[activity_dep],packageProductDependencies=app_product_deps)
proxy=add('proxy','PBXContainerItemProxy',containerPortal=project_id,proxyType=1,remoteGlobalIDString=app_target,remoteInfo='WakeOn')
dep=add('dependency','PBXTargetDependency',target=app_target,targetProxy=proxy)
test_settings=dict(common,ONLY_ACTIVE_ARCH='YES',PRODUCT_NAME='$(TARGET_NAME)',PRODUCT_BUNDLE_IDENTIFIER='com.kamikaz1k.wakeon.tests',GENERATE_INFOPLIST_FILE='YES',TEST_HOST='$(BUILT_PRODUCTS_DIR)/WakeOn.app/$(BUNDLE_EXECUTABLE_FOLDER_PATH)/WakeOn',BUNDLE_LOADER='$(TEST_HOST)',SWIFT_OBJC_BRIDGING_HEADER='WakeOn/Bridge.h',HEADER_SEARCH_PATHS=appsettings['HEADER_SEARCH_PATHS'])
test_target=add('tests','PBXNativeTarget',name='WakeOnTests',productName='WakeOnTests',productReference=test_product,productType='com.apple.product-type.bundle.unit-test',buildConfigurationList=configs('tests',test_settings),buildPhases=[phase('testSources','PBXSourcesBuildPhase',tests),phase('testFrameworks','PBXFrameworksBuildPhase',[])],buildRules=[],dependencies=[dep])
lab_settings=dict(common,IPHONEOS_DEPLOYMENT_TARGET='18.0',ONLY_ACTIVE_ARCH='YES',PRODUCT_BUNDLE_IDENTIFIER='com.kamikaz1k.chatlab',PRODUCT_NAME='$(TARGET_NAME)',INFOPLIST_FILE='ChatLab/Info.plist',LD_RUNPATH_SEARCH_PATHS=['$(inherited)','@executable_path/Frameworks'])
lab_frameworks=add('labFrameworks','PBXFrameworksBuildPhase',buildActionMask=2147483647,files=lab_framework_files,runOnlyForDeploymentPostprocessing=0)
# LanguageModelChatUI is a dynamic library product: Xcode links it but only embeds it when told.
# Without this the simulator finds it in the build folder and the phone crashes at launch.
lab_embed_files=[add('labembed'+d,'PBXBuildFile',productRef=d,settings={'ATTRIBUTES':['CodeSignOnCopy','RemoveHeadersOnCopy']}) for d in lab_product_deps if objects[d]['productName']=='LanguageModelChatUI']
lab_embed=add('labEmbedFrameworks','PBXCopyFilesBuildPhase',buildActionMask=2147483647,dstPath='',dstSubfolderSpec=10,files=lab_embed_files,name='Embed Frameworks',runOnlyForDeploymentPostprocessing=0)
lab_target=add('labapp','PBXNativeTarget',name='ChatLab',productName='ChatLab',productReference=lab_app,productType='com.apple.product-type.application',buildConfigurationList=configs('lab',lab_settings),buildPhases=[phase('labSources','PBXSourcesBuildPhase',lab_sources+chat_ui,prefix='labbuild'),lab_frameworks,phase('labResources','PBXResourcesBuildPhase',lab_resources),lab_embed],buildRules=[],dependencies=[],packageProductDependencies=lab_product_deps)
# Chat Lab UI tests: real swipes in the simulator (e.g. overscrolling a library's list).
lab_proxy=add('labProxy','PBXContainerItemProxy',containerPortal=project_id,proxyType=1,remoteGlobalIDString=lab_target,remoteInfo='ChatLab')
lab_dep=add('labDependency','PBXTargetDependency',target=lab_target,targetProxy=lab_proxy)
lab_ui_settings=dict(common,IPHONEOS_DEPLOYMENT_TARGET='18.0',ONLY_ACTIVE_ARCH='YES',PRODUCT_NAME='$(TARGET_NAME)',PRODUCT_BUNDLE_IDENTIFIER='com.kamikaz1k.chatlab.uitests',GENERATE_INFOPLIST_FILE='YES',TEST_TARGET_NAME='ChatLab')
lab_ui_target=add('labuitests','PBXNativeTarget',name='ChatLabUITests',productName='ChatLabUITests',productReference=lab_ui_product,productType='com.apple.product-type.bundle.ui-testing',buildConfigurationList=configs('labui',lab_ui_settings),buildPhases=[phase('labUISources','PBXSourcesBuildPhase',lab_ui_sources),phase('labUIFrameworks','PBXFrameworksBuildPhase',[])],buildRules=[],dependencies=[lab_dep])
add('project','PBXProject',packageReferences=lab_package_refs,attributes={'LastUpgradeCheck':'2600'},buildConfigurationList=configs('project',common),compatibilityVersion='Xcode 14.0',developmentRegion='en',hasScannedForEncodings=0,knownRegions=['en','Base'],mainGroup=group,productRefGroup=products,projectDirPath='',projectRoot='',targets=[app_target,test_target,activity_target,lab_target,lab_ui_target])
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
info=dict(CFBundleDevelopmentRegion='en',CFBundleExecutable='$(EXECUTABLE_NAME)',CFBundleIdentifier='$(PRODUCT_BUNDLE_IDENTIFIER)',CFBundleInfoDictionaryVersion='6.0',CFBundleName='Pixie',CFBundleDisplayName='Pixie',CFBundlePackageType='APPL',CFBundleShortVersionString='0.1.0',CFBundleVersion='$(CURRENT_PROJECT_VERSION)',LSRequiresIPhoneOS=True,NSMicrophoneUsageDescription='Listen locally for Hey Lobby, keep a short audio buffer for the wake handoff, and talk with the voice assistant.',NSCameraUsageDescription='Pixie doesn’t use your camera: calls with Lobby are voice only. A website you open in Pixie’s browser could ask for it, and iOS asks you first.',UIBackgroundModes=['audio'],NSSupportsLiveActivities=True,UILaunchScreen={},UISupportedInterfaceOrientations=['UIInterfaceOrientationPortrait','UIInterfaceOrientationLandscapeLeft','UIInterfaceOrientationLandscapeRight'],UIApplicationSceneManifest={'UIApplicationSupportsMultipleScenes':False},ITSAppUsesNonExemptEncryption=False,CFBundleURLTypes=[{'CFBundleURLName':'com.kamikaz1k.wakeon','CFBundleURLSchemes':['wakeon']}])
info['UISupportedInterfaceOrientations~ipad'] = info['UISupportedInterfaceOrientations'] + ['UIInterfaceOrientationPortraitUpsideDown']
(root/'WakeOn/Info.plist').write_bytes(plistlib.dumps(info))

activity_info=dict(CFBundleDevelopmentRegion='en',CFBundleDisplayName='Pixie',CFBundleExecutable='$(EXECUTABLE_NAME)',CFBundleIdentifier='$(PRODUCT_BUNDLE_IDENTIFIER)',CFBundleInfoDictionaryVersion='6.0',CFBundleName='$(PRODUCT_NAME)',CFBundlePackageType='XPC!',CFBundleShortVersionString=info['CFBundleShortVersionString'],CFBundleVersion=info['CFBundleVersion'],NSExtension={'NSExtensionPointIdentifier':'com.apple.widgetkit-extension'})
(root/'WakeOnLiveActivity/Info.plist').write_bytes(plistlib.dumps(activity_info))

(scheme/'ChatLab.xcscheme').write_text(f'''<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion="2600" version="1.3">
<BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES"><BuildActionEntries><BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="YES" buildForArchiving="YES" buildForAnalyzing="YES">{ref(lab_target,'ChatLab.app')}</BuildActionEntry></BuildActionEntries></BuildAction>
<TestAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB"><Testables><TestableReference skipped="NO">{ref(lab_ui_target,'ChatLabUITests.xctest')}</TestableReference></Testables></TestAction>
<LaunchAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" launchStyle="0" useCustomWorkingDirectory="NO" ignoresPersistentStateOnLaunch="NO" debugDocumentVersioning="YES" allowLocationSimulation="YES"><BuildableProductRunnable runnableDebuggingMode="0">{ref(lab_target,'ChatLab.app')}</BuildableProductRunnable></LaunchAction>
<ProfileAction buildConfiguration="Release"><BuildableProductRunnable runnableDebuggingMode="0">{ref(lab_target,'ChatLab.app')}</BuildableProductRunnable></ProfileAction>
<AnalyzeAction buildConfiguration="Debug"/><ArchiveAction buildConfiguration="Release" revealArchiveInOrganizer="YES"/>
</Scheme>''')
lab_info=dict(CFBundleDevelopmentRegion='en',CFBundleDisplayName='Chat Lab',CFBundleExecutable='$(EXECUTABLE_NAME)',CFBundleIdentifier='$(PRODUCT_BUNDLE_IDENTIFIER)',CFBundleInfoDictionaryVersion='6.0',CFBundleName='Chat Lab',CFBundlePackageType='APPL',CFBundleShortVersionString='0.1.0',CFBundleVersion='1',LSRequiresIPhoneOS=True,UILaunchScreen={},UISupportedInterfaceOrientations=['UIInterfaceOrientationPortrait'],UIApplicationSceneManifest={'UIApplicationSupportsMultipleScenes':False},ITSAppUsesNonExemptEncryption=False,NSPhotoLibraryUsageDescription='Not used; required by a chat library.',NSCameraUsageDescription='Not used; required by a chat library.',NSMicrophoneUsageDescription='Not used; required by a chat library.',NSSpeechRecognitionUsageDescription='Not used; required by a chat library.',NSLocationWhenInUseUsageDescription='Not used; required by a chat library.',UIFileSharingEnabled=True,LSSupportsOpeningDocumentsInPlace=True)
(root/'ChatLab/Info.plist').write_bytes(plistlib.dumps(lab_info))
