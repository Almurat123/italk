import { createHash } from 'node:crypto';
import { mkdirSync, readFileSync, readdirSync, writeFileSync } from 'node:fs';
import { resolve, relative } from 'node:path';

const root = resolve(import.meta.dirname, '..');
const objects = {};
const id = name => createHash('sha256').update(name).digest('hex').slice(0, 24).toUpperCase();
function add(name, value) { const key = id(name); objects[key] = value; return key; }
function plist(value, indent = '') {
  if (Array.isArray(value)) return `(\n${value.map(v => indent + '  ' + plist(v, indent + '  ') + ',').join('\n')}\n${indent})`;
  if (value && typeof value === 'object') return `{\n${Object.entries(value).map(([k, v]) => `${indent}  ${JSON.stringify(k)} = ${plist(v, indent + '  ')};`).join('\n')}\n${indent}}`;
  return typeof value === 'number' ? String(value) : JSON.stringify(value);
}
function xml(value) {
  if (Array.isArray(value)) return `<array>${value.map(xml).join('')}</array>`;
  if (typeof value === 'boolean') return value ? '<true/>' : '<false/>';
  if (value && typeof value === 'object') return `<dict>${Object.entries(value).map(([key, val]) => `<key>${key}</key>${xml(val)}`).join('')}</dict>`;
  return `<string>${String(value).replaceAll('&', '&amp;').replaceAll('<', '&lt;')}</string>`;
}
function xmlFile(path, value) {
  mkdirSync(resolve(root, path, '..'), { recursive: true });
  writeFileSync(resolve(root, path), `<?xml version="1.0" encoding="UTF-8"?>\n<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">\n<plist version="1.0">${xml(value)}</plist>\n`);
}
const files = dir => readdirSync(resolve(root, dir)).filter(n => n.endsWith('.swift') || n.endsWith('.metal')).map(n => `${dir}/${n}`);
const targets = [
  { name: 'iTalk', bundle: 'com.italk.assistant', platform: 'iphoneos', supported: 'iphoneos iphonesimulator', sources: [...files('apps/Shared'), ...files('apps/iOS')], core: true, local: true },
  { name: 'iTalkWatch', bundle: 'com.italk.assistant.watchkitapp', platform: 'watchos', supported: 'watchos watchsimulator', sources: [...files('apps/Shared').filter(path => !path.endsWith('/AssistantView.swift')), ...files('apps/Watch')], core: true },
  { name: 'iTalkControls', bundle: 'com.italk.assistant.controls', platform: 'iphoneos', supported: 'iphoneos iphonesimulator', sources: [...files('apps/iOSWidgets'), 'apps/Shared/Activation.swift', 'apps/Shared/AgentActivityAttributes.swift'], extension: true },
  { name: 'iTalkComplications', bundle: 'com.italk.assistant.watchkitapp.complications', platform: 'watchos', supported: 'watchos watchsimulator', sources: files('apps/WatchWidgets'), extension: true }
];
const fileRefs = new Map();
for (const path of new Set(targets.flatMap(t => t.sources))) {
  fileRefs.set(path, add(`file:${path}`, { isa: 'PBXFileReference', lastKnownFileType: path.endsWith('.metal') ? 'sourcecode.metal' : 'sourcecode.swift', path, sourceTree: 'SOURCE_ROOT' }));
}
const products = targets.map(t => add(`product:${t.name}`, { isa: 'PBXFileReference', explicitFileType: t.extension ? 'wrapper.app-extension' : 'wrapper.application', path: `${t.name}.${t.extension ? 'appex' : 'app'}`, sourceTree: 'BUILT_PRODUCTS_DIR' }));
const productGroup = add('group:products', { isa: 'PBXGroup', name: 'Products', children: products, sourceTree: '<group>' });
const sourcesGroup = add('group:sources', { isa: 'PBXGroup', name: 'Sources', children: [...fileRefs.values()], sourceTree: '<group>' });
const appAssets = add('file:ios-assets', { isa: 'PBXFileReference', lastKnownFileType: 'folder.assetcatalog', path: 'apps/iOS/Assets.xcassets', sourceTree: 'SOURCE_ROOT' });
objects[sourcesGroup].children.push(appAssets);
const mainGroup = add('group:main', { isa: 'PBXGroup', children: [sourcesGroup, productGroup], sourceTree: '<group>' });
const packageRef = add('package:core', { isa: 'XCLocalSwiftPackageReference', relativePath: 'Packages/AssistantCore' });
// On-device agent runtime and MLX inference: iPhone app target only (never the Watch targets).
const runtimeRef = add('package:runtime', { isa: 'XCLocalSwiftPackageReference', relativePath: 'Packages/AgentRuntime' });
const inferenceRef = add('package:inference', { isa: 'XCLocalSwiftPackageReference', relativePath: 'Packages/LocalInference' });
const speechRef = add('package:speech', { isa: 'XCLocalSwiftPackageReference', relativePath: 'Packages/NeuralSpeech' });
// Apple capability skills (real executors for system frameworks): iPhone app only.
const appleSkillsRef = add('package:appleskills', { isa: 'XCLocalSwiftPackageReference', relativePath: 'Packages/AppleSkills' });
// Pairing and talking to the person's own computers (remote/agent): iPhone app only.
const remoteRef = add('package:remoteagent', { isa: 'XCLocalSwiftPackageReference', relativePath: 'Packages/RemoteAgent' });
// Public URL schemes iTalk may query with canOpenURL (app_open / maps_open). Keep in sync with AppLinks.querySchemes.
const querySchemes = ['weixin', 'alipay', 'iosamap', 'baidumap', 'taobao', 'openapp.jdmobile', 'imeituan', 'dianping', 'eleme', 'diditaxi', 'snssdk1128', 'bilibili', 'sinaweibo', 'xhsdiscover', 'zhihu', 'mqq', 'qqmusic', 'orpheus', 'dingtalk', 'lark', 'ctrip', 'pinduoduo', 'shortcuts', 'camera', 'alipays', 'facetime-audio', 'facetime', 'tel', 'sms'];
function configs(name, settings) {
  const buildConfigurations = ['Debug', 'Release'].map(configuration => add(`config:${name}:${configuration}`, { isa: 'XCBuildConfiguration', name: configuration, buildSettings: {
    ...settings, SWIFT_OPTIMIZATION_LEVEL: configuration === 'Debug' ? '-Onone' : '-O', SWIFT_ACTIVE_COMPILATION_CONDITIONS: configuration === 'Debug' ? 'DEBUG' : '', DEBUG_INFORMATION_FORMAT: configuration === 'Debug' ? 'dwarf' : 'dwarf-with-dsym'
  } }));
  return add(`configlist:${name}`, { isa: 'XCConfigurationList', buildConfigurations, defaultConfigurationIsVisible: 0, defaultConfigurationName: 'Release' });
}
// CONTEXT MEMORY
// Updated: 2026-10-28
// Status: inferred
// Why: Regenerating the project must preserve an existing Xcode signing team.
// Debug Goal: A developer can run every app and extension target on their device.
// Search Tags: Xcode development team project regeneration signing
// Invariants:
// - ITALK_TEAM explicitly overrides the previously selected team.
// - Conflicting existing team values are not guessed.
// Failure Modes:
// - Regeneration clears the team and all device targets fail signing.
// - A different developer's team is silently selected.
function existingDevelopmentTeam() {
  try {
    const project = readFileSync(resolve(root, 'iTalk.xcodeproj/project.pbxproj'), 'utf8');
    const teams = new Set([...project.matchAll(/"?DEVELOPMENT_TEAM"?\s*=\s*"?([A-Z0-9]{10})"?\s*;/g)].map(match => match[1]));
    return teams.size === 1 ? [...teams][0] : '';
  } catch (error) {
    if (error.code === 'ENOENT') return '';
    throw error;
  }
}

// The managed cloud gateway's public HTTPS base URL, baked into the app so people never type a host. It lives in config/cloud-endpoint.txt
// (git-ignored, survives regeneration by either session) or ITALK_CLOUD_ENDPOINT. Empty = the app reports the cloud service as not deployed.
function cloudEndpoint() {
  let value = process.env.ITALK_CLOUD_ENDPOINT ?? '';
  try { value = readFileSync(resolve(root, 'config/cloud-endpoint.txt'), 'utf8').trim() || value; } catch (error) { if (error.code !== 'ENOENT') throw error; }
  if (value && !/^https:\/\/[A-Za-z0-9.-]+(:\d+)?(\/[A-Za-z0-9._~\/-]*)?$/.test(value)) throw new Error(`ITalkCloudEndpoint must be a plain https URL, got ${value}`);
  return value.replace(/\/+$/, '');
}

const projectConfigs = configs('project', { SWIFT_VERSION: '6.0', CLANG_ENABLE_MODULES: 'YES', SWIFT_STRICT_CONCURRENCY: 'complete', ENABLE_USER_SCRIPT_SANDBOXING: 'YES', CODE_SIGN_STYLE: 'Automatic', DEVELOPMENT_TEAM: process.env.ITALK_TEAM ?? existingDevelopmentTeam(), CURRENT_PROJECT_VERSION: '7', MARKETING_VERSION: '0.7.0', LOCALIZATION_PREFERS_STRING_CATALOGS: 'YES', DEVELOPMENT_LANGUAGE: 'zh-Hans' });
for (const [index, target] of targets.entries()) {
  const watch = target.platform === 'watchos';
  const sourcesPhase = add(`sources:${target.name}`, { isa: 'PBXSourcesBuildPhase', buildActionMask: 2147483647, files: target.sources.map(path => add(`build:${target.name}:${path}`, { isa: 'PBXBuildFile', fileRef: fileRefs.get(path) })), runOnlyForDeploymentPostprocessing: 0 });
  const frameworks = [];
  const packageProducts = [];
  if (target.core) {
    const product = add(`dependency:core:${target.name}`, { isa: 'XCSwiftPackageProductDependency', package: packageRef, productName: 'AssistantCore' });
    packageProducts.push(product);
    frameworks.push(add(`link:core:${target.name}`, { isa: 'PBXBuildFile', productRef: product }));
  }
  if (target.local) {
    for (const [ref, productName] of [[runtimeRef, 'AgentRuntime'], [inferenceRef, 'MLXProvider'], [speechRef, 'NeuralSpeech'], [appleSkillsRef, 'AppleSkills'], [remoteRef, 'RemoteAgent']]) {
      const product = add(`dependency:${productName}:${target.name}`, { isa: 'XCSwiftPackageProductDependency', package: ref, productName });
      packageProducts.push(product);
      frameworks.push(add(`link:${productName}:${target.name}`, { isa: 'PBXBuildFile', productRef: product }));
    }
  }
  const frameworksPhase = add(`frameworks:${target.name}`, { isa: 'PBXFrameworksBuildPhase', buildActionMask: 2147483647, files: frameworks, runOnlyForDeploymentPostprocessing: 0 });
  const resources = add(`resources:${target.name}`, { isa: 'PBXResourcesBuildPhase', buildActionMask: 2147483647, files: target.name === 'iTalk' ? [add('build:ios-assets', { isa: 'PBXBuildFile', fileRef: appAssets })] : [], runOnlyForDeploymentPostprocessing: 0 });
  const info = {
    CFBundleDevelopmentRegion: 'zh_CN', CFBundleDisplayName: 'iTalk', CFBundleExecutable: '$(EXECUTABLE_NAME)', CFBundleIdentifier: '$(PRODUCT_BUNDLE_IDENTIFIER)', CFBundleInfoDictionaryVersion: '6.0', CFBundleName: '$(PRODUCT_NAME)', CFBundlePackageType: target.extension ? 'XPC!' : 'APPL', CFBundleShortVersionString: '$(MARKETING_VERSION)', CFBundleVersion: '$(CURRENT_PROJECT_VERSION)',
    ...(target.extension ? { NSExtension: { NSExtensionPointIdentifier: 'com.apple.widgetkit-extension' } } : {
      CFBundleURLTypes: [{ CFBundleURLSchemes: ['italk'], CFBundleURLName: target.bundle }],
      NSMicrophoneUsageDescription: '你开始语音对话后，用麦克风识别普通话；对话进行中锁屏或切到其他 App 会继续收音，直到你暂停。',
      NSHealthShareUsageDescription: '在设备上读取你允许的健康数据（步数、睡眠、心率等）来回答问题；默认不上传健康数据。',
      NSCalendarsFullAccessUsageDescription: '查询日程，并在你核对确认后创建或删除日程。',
      NSRemindersFullAccessUsageDescription: '查询提醒，并在你核对确认后保存提醒事项。',
      ...(watch ? {} : {
        NSContactsUsageDescription: '你让 iTalk 找人、发消息或打电话时，查找联系人的电话和邮箱。',
        NSPhotoLibraryUsageDescription: '你让 iTalk 找照片或识别照片内容时读取相册；识别在设备上完成。',
        NSPhotoLibraryAddUsageDescription: '把你让 iTalk 生成或保存的图片存入相册。',
        NSLocationWhenInUseUsageDescription: '查询附近地点、路线和本地天气时使用你的位置。',
        NSCameraUsageDescription: '你让 iTalk 拍照识别文字、物体或二维码时使用相机。',
      NSLocalNetworkUsageDescription: '连接你自己的电脑（扫码配对后），在同一网络内与电脑上的 iTalk 助手通信。',
        NSHomeKitUsageDescription: '查看并控制你在“家庭”App 中的灯、开关、空调和门锁。',
        NSAppleMusicUsageDescription: '播放你音乐资料库中的歌曲和播放列表。',
        NSMotionUsageDescription: '读取 iPhone 记录的步数和运动状态。',
        NSBluetoothAlwaysUsageDescription: '扫描附近的蓝牙设备。',
        NFCReaderUsageDescription: '读取你靠近的 NFC 标签。',
        NSAlarmKitUsageDescription: '为你设置闹钟和倒计时，即使静音也会提醒。',
        NSSpeechRecognitionUsageDescription: '把你导入的录音转成文字（在设备上完成）。',
        LSApplicationQueriesSchemes: querySchemes,
        UIBackgroundModes: ['audio'],
        ITalkCloudEndpoint: cloudEndpoint(),
        ITalkHomeKitEnabled: process.env.ITALK_EXTENDED_CAPABILITIES === '1',
        ITalkNFCEnabled: process.env.ITALK_EXTENDED_CAPABILITIES === '1',
        NSSupportsLiveActivities: true,
        UIFileSharingEnabled: true,
        LSSupportsOpeningDocumentsInPlace: true
      }),
      SKIncludeConsumableInAppPurchaseHistory: true,
      ...(watch ? { WKApplication: true, WKCompanionAppBundleIdentifier: 'com.italk.assistant', WKRunsIndependentlyOfCompanionApp: true } : {
        UILaunchScreen: {}, BGTaskSchedulerPermittedIdentifiers: ['com.italk.assistant.model-download.*'], UIApplicationSceneManifest: { UIApplicationSupportsMultipleScenes: false }, UISupportedInterfaceOrientations: ['UIInterfaceOrientationPortrait']
      })
    })
  };
  xmlFile(`config/${target.name}-Info.plist`, info);
  // HomeKit and NFC need those capabilities on the App ID (Xcode › Signing & Capabilities, signed in). Opt in with
  // ITALK_EXTENDED_CAPABILITIES=1 once the profile has them; the app reports the tools as unavailable otherwise.
  const extended = process.env.ITALK_EXTENDED_CAPABILITIES === '1';
  if (target.core) xmlFile(`config/${target.name}.entitlements`, watch || !extended ? { 'com.apple.developer.healthkit': true } : {
    'com.apple.developer.healthkit': true, 'com.apple.developer.homekit': true,
    'com.apple.developer.nfc.readersession.formats': ['TAG']
  });
  const settings = {
    PRODUCT_NAME: '$(TARGET_NAME)', PRODUCT_BUNDLE_IDENTIFIER: target.bundle, SDKROOT: target.platform, SUPPORTED_PLATFORMS: target.supported,
    ...(target.name === 'iTalk' ? { ASSETCATALOG_COMPILER_APPICON_NAME: 'AppIcon', ASSETCATALOG_COMPILER_ALTERNATE_APPICON_NAMES: 'OrbCircle', ASSETCATALOG_COMPILER_INCLUDE_ALL_APPICON_ASSETS: 'YES' } : {}),
    INFOPLIST_FILE: `config/${target.name}-Info.plist`, GENERATE_INFOPLIST_FILE: 'NO', TARGETED_DEVICE_FAMILY: watch ? '4' : '1',
    ...(watch ? { WATCHOS_DEPLOYMENT_TARGET: '26.0' } : { IPHONEOS_DEPLOYMENT_TARGET: '26.0', SUPPORTS_MACCATALYST: 'NO', SUPPORTS_MAC_DESIGNED_FOR_IPHONE_IPAD: 'NO' }),
    ...(target.extension ? { APPLICATION_EXTENSION_API_ONLY: 'YES', SKIP_INSTALL: 'YES' } : { CODE_SIGN_ENTITLEMENTS: `config/${target.name}.entitlements` })
  };
  add(`target:${target.name}`, { isa: 'PBXNativeTarget', buildConfigurationList: configs(target.name, settings), buildPhases: [sourcesPhase, frameworksPhase, resources], buildRules: [], dependencies: [], name: target.name, packageProductDependencies: packageProducts, productName: target.name, productReference: products[index], productType: target.extension ? 'com.apple.product-type.app-extension' : 'com.apple.product-type.application' });
}
function embed(parent, child, destination, path = '') {
  const proxy = add(`proxy:${parent}:${child}`, { isa: 'PBXContainerItemProxy', containerPortal: id('project'), proxyType: 1, remoteGlobalIDString: id(`target:${child}`), remoteInfo: child });
  const dependency = add(`depends:${parent}:${child}`, { isa: 'PBXTargetDependency', target: id(`target:${child}`), targetProxy: proxy });
  objects[id(`target:${parent}`)].dependencies.push(dependency);
  const build = add(`embedfile:${parent}:${child}`, { isa: 'PBXBuildFile', fileRef: id(`product:${child}`), settings: { ATTRIBUTES: ['RemoveHeadersOnCopy'] } });
  const phase = add(`embed:${parent}:${child}`, { isa: 'PBXCopyFilesBuildPhase', buildActionMask: 2147483647, dstPath: path, dstSubfolderSpec: destination, files: [build], name: `Embed ${child}`, runOnlyForDeploymentPostprocessing: 0 });
  objects[id(`target:${parent}`)].buildPhases.push(phase);
}
embed('iTalk', 'iTalkControls', 13);
embed('iTalk', 'iTalkWatch', 16, '$(CONTENTS_FOLDER_PATH)/Watch');
embed('iTalkWatch', 'iTalkComplications', 13);
const uiTestSource = add('file:uitests', { isa: 'PBXFileReference', lastKnownFileType: 'sourcecode.swift', path: 'apps/UITests/AssistantUITests.swift', sourceTree: 'SOURCE_ROOT' });
objects[sourcesGroup].children.push(uiTestSource);
const uiTestProduct = add('product:uitests', { isa: 'PBXFileReference', explicitFileType: 'wrapper.cfbundle', path: 'iTalkUITests.xctest', sourceTree: 'BUILT_PRODUCTS_DIR' });
objects[productGroup].children.push(uiTestProduct);
const uiTestSources = add('sources:uitests', { isa: 'PBXSourcesBuildPhase', buildActionMask: 2147483647, files: [add('build:uitests', { isa: 'PBXBuildFile', fileRef: uiTestSource })], runOnlyForDeploymentPostprocessing: 0 });
const testProxy = add('proxy:uitests', { isa: 'PBXContainerItemProxy', containerPortal: id('project'), proxyType: 1, remoteGlobalIDString: id('target:iTalk'), remoteInfo: 'iTalk' });
const testDependency = add('dependency:uitests', { isa: 'PBXTargetDependency', target: id('target:iTalk'), targetProxy: testProxy });
const testTarget = add('target:uitests', { isa: 'PBXNativeTarget', name: 'iTalkUITests', productName: 'iTalkUITests', productType: 'com.apple.product-type.bundle.ui-testing', productReference: uiTestProduct, buildPhases: [uiTestSources], buildRules: [], dependencies: [testDependency], buildConfigurationList: configs('uitests', { PRODUCT_NAME: '$(TARGET_NAME)', PRODUCT_BUNDLE_IDENTIFIER: 'com.italk.assistant.uitests', SDKROOT: 'iphoneos', SUPPORTED_PLATFORMS: 'iphoneos iphonesimulator', IPHONEOS_DEPLOYMENT_TARGET: '26.0', TARGETED_DEVICE_FAMILY: '1', GENERATE_INFOPLIST_FILE: 'YES', TEST_TARGET_NAME: 'iTalk' }) });
const project = add('project', { isa: 'PBXProject', attributes: { BuildIndependentTargetsInParallel: 'YES', LastUpgradeCheck: '2700' }, buildConfigurationList: projectConfigs, compatibilityVersion: 'Xcode 16.0', developmentRegion: 'zh-Hans', hasScannedForEncodings: 0, knownRegions: ['zh-Hans', 'en', 'Base'], mainGroup, productRefGroup: productGroup, projectDirPath: '', projectRoot: '', packageReferences: [packageRef, runtimeRef, inferenceRef, speechRef, appleSkillsRef, remoteRef], targets: [...targets.map(t => id(`target:${t.name}`)), testTarget] });
mkdirSync(resolve(root, 'iTalk.xcodeproj/xcshareddata/xcschemes'), { recursive: true });
writeFileSync(resolve(root, 'iTalk.xcodeproj/project.pbxproj'), '// !$*UTF8*$!\n' + plist({ archiveVersion: 1, classes: {}, objectVersion: 77, objects, rootObject: project }) + '\n');
for (const target of targets.filter(t => !t.extension)) {
  const scheme = `<?xml version="1.0" encoding="UTF-8"?><Scheme LastUpgradeVersion="2700" version="1.3"><BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES"><BuildActionEntries><BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="YES" buildForArchiving="YES" buildForAnalyzing="YES"><BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="${id(`target:${target.name}`)}" BuildableName="${target.name}.app" BlueprintName="${target.name}" ReferencedContainer="container:iTalk.xcodeproj"/></BuildActionEntry></BuildActionEntries></BuildAction><LaunchAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" launchStyle="0" useCustomWorkingDirectory="NO" ignoresPersistentStateOnLaunch="NO" debugDocumentVersioning="YES" debugServiceExtension="internal" allowLocationSimulation="YES"><BuildableProductRunnable runnableDebuggingMode="0"><BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="${id(`target:${target.name}`)}" BuildableName="${target.name}.app" BlueprintName="${target.name}" ReferencedContainer="container:iTalk.xcodeproj"/></BuildableProductRunnable></LaunchAction><ArchiveAction buildConfiguration="Release" revealArchiveInOrganizer="YES"/></Scheme>`;
  const testAction = target.name === 'iTalk' ? `<TestAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB"><Testables><TestableReference skipped="NO"><BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="${testTarget}" BuildableName="iTalkUITests.xctest" BlueprintName="iTalkUITests" ReferencedContainer="container:iTalk.xcodeproj"/></TestableReference></Testables></TestAction>` : '';
  writeFileSync(resolve(root, `iTalk.xcodeproj/xcshareddata/xcschemes/${target.name}.xcscheme`), scheme.replace('<LaunchAction', testAction + '<LaunchAction') + '\n');
}
console.log('Generated iTalk.xcodeproj and platform configuration.');
