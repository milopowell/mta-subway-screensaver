"""Generate swift/SubwaySaver.xcodeproj/project.pbxproj (Xcode 16+ format with folder-synced groups)."""
from pathlib import Path

PROJECT = Path(__file__).resolve().parents[1]  # ~/mta-screensaver
OUT = PROJECT / "swift/SubwaySaver.xcodeproj/project.pbxproj"

ids = {}


import hashlib


def i(name):
    """Stable 24-hex-digit object ID derived from a name, so regenerating never reshuffles IDs."""
    ids[name] = hashlib.md5(name.encode()).hexdigest()[:24].upper()
    return ids[name]


PACKAGE_URL = "https://github.com/apple/swift-protobuf.git"
PACKAGE_MIN = "1.39.0"  # must be at least the protoc-gen-swift version that generated gtfs-realtime.pb.swift


common_target = {
    "CODE_SIGN_IDENTITY": '"-"',  # ad-hoc "Sign to Run Locally": no Apple developer account needed
    "CODE_SIGN_STYLE": "Manual",
    "DEVELOPMENT_TEAM": '""',
    "GENERATE_INFOPLIST_FILE": "YES",
    "MARKETING_VERSION": "0.1",
    "CURRENT_PROJECT_VERSION": "1",
    "SWIFT_EMIT_LOC_STRINGS": "NO",
    "PRODUCT_NAME": '"$(TARGET_NAME)"',
}
targets = {
    "SubwayPreview": {
        "groups": ["Shared", "PreviewApp", "export"],
        "product": "SubwayPreview.app",
        "file_type": "wrapper.application",
        "product_type": '"com.apple.product-type.application"',
        "settings": {
            **common_target,
            "PRODUCT_BUNDLE_IDENTIFIER": "com.milopowell.subway.preview",
            "INFOPLIST_KEY_NSPrincipalClass": "NSApplication",
            "INFOPLIST_KEY_CFBundleDisplayName": '"Subway Preview"',
            "INFOPLIST_KEY_LSApplicationCategoryType": '"public.app-category.utilities"',
            "LD_RUNPATH_SEARCH_PATHS": '"@executable_path/../Frameworks"',
            "COMBINE_HIDPI_IMAGES": "YES",
        },
    },
    "SubwaySaver": {
        "groups": ["Shared", "Saver", "export"],
        "product": "SubwaySaver.saver",
        "file_type": "wrapper.cfbundle",
        "product_type": '"com.apple.product-type.bundle"',
        "settings": {
            **common_target,
            "PRODUCT_BUNDLE_IDENTIFIER": "com.milopowell.subway.saver",
            "WRAPPER_EXTENSION": "saver",
            "INFOPLIST_KEY_NSPrincipalClass": "SubwaySaverView",
            "INFOPLIST_KEY_CFBundleDisplayName": '"Subway"',
            "INSTALL_PATH": '"$(HOME)/Library/Screen Savers"',
            "LD_RUNPATH_SEARCH_PATHS": '"@loader_path/../Frameworks"',
            "COMBINE_HIDPI_IMAGES": "YES",
        },
    },
}
project_settings = {
    "Debug": {
        "ALWAYS_SEARCH_USER_PATHS": "NO",
        "CLANG_ENABLE_MODULES": "YES",
        "DEBUG_INFORMATION_FORMAT": "dwarf",
        "ENABLE_TESTABILITY": "YES",
        "MACOSX_DEPLOYMENT_TARGET": "14.0",
        "ONLY_ACTIVE_ARCH": "YES",
        "SDKROOT": "macosx",
        "SWIFT_ACTIVE_COMPILATION_CONDITIONS": '"DEBUG $(inherited)"',
        "SWIFT_OPTIMIZATION_LEVEL": '"-Onone"',
        "SWIFT_VERSION": "5.0",
    },
    "Release": {
        "ALWAYS_SEARCH_USER_PATHS": "NO",
        "CLANG_ENABLE_MODULES": "YES",
        "DEBUG_INFORMATION_FORMAT": '"dwarf-with-dsym"',
        "MACOSX_DEPLOYMENT_TARGET": "14.0",
        "SDKROOT": "macosx",
        "SWIFT_COMPILATION_MODE": "wholemodule",
        "SWIFT_OPTIMIZATION_LEVEL": '"-O"',
        "SWIFT_VERSION": "5.0",
    },
}

folders = {"Shared": "Shared", "PreviewApp": "PreviewApp", "Saver": "Saver", "export": "../export"}


def settings_block(d, indent):
    pad = "\t" * indent
    return "".join(f"{pad}{k} = {v};\n" for k, v in d.items())


lines = ["// !$*UTF8*$!", "{", "\tarchiveVersion = 1;", "\tclasses = {", "\t};", "\tobjectVersion = 77;", "\tobjects = {", ""]

lines.append("/* Begin PBXBuildFile section */")
for t in targets:
    lines.append(f"\t\t{i(t + '.protobuf.buildfile')} /* SwiftProtobuf in Frameworks */ = {{isa = PBXBuildFile; "
                 f"productRef = {i(t + '.protobuf.product')} /* SwiftProtobuf */; }};")
lines.append("/* End PBXBuildFile section */\n")

lines.append("/* Begin PBXFileReference section */")
for t, spec in targets.items():
    lines.append(f"\t\t{i(t + '.product')} /* {spec['product']} */ = {{isa = PBXFileReference; explicitFileType = {spec['file_type']}; "
                 f"includeInIndex = 0; path = {spec['product']}; sourceTree = BUILT_PRODUCTS_DIR; }};")
lines.append("/* End PBXFileReference section */\n")

lines.append("/* Begin PBXFileSystemSynchronizedRootGroup section */")
for name, path in folders.items():
    lines.append(f"\t\t{i('group.' + name)} /* {name} */ = {{isa = PBXFileSystemSynchronizedRootGroup; "
                 f"name = {name}; path = {path}; sourceTree = \"<group>\"; }};")
lines.append("/* End PBXFileSystemSynchronizedRootGroup section */\n")

lines.append("/* Begin PBXFrameworksBuildPhase section */")
for t in targets:
    lines.append(f"\t\t{i(t + '.frameworks')} /* Frameworks */ = {{isa = PBXFrameworksBuildPhase; buildActionMask = 2147483647; "
                 f"files = ({i(t + '.protobuf.buildfile')} /* SwiftProtobuf in Frameworks */, ); runOnlyForDeploymentPostprocessing = 0; }};")
lines.append("/* End PBXFrameworksBuildPhase section */\n")

lines.append("/* Begin PBXGroup section */")
children = "".join(f"\t\t\t\t{i('group.' + n)} /* {n} */,\n" for n in folders)
lines.append(f"\t\t{i('mainGroup')} = {{\n\t\t\tisa = PBXGroup;\n\t\t\tchildren = (\n{children}\t\t\t\t{i('productsGroup')} /* Products */,\n"
             f"\t\t\t);\n\t\t\tsourceTree = \"<group>\";\n\t\t}};")
prods = "".join(f"\t\t\t\t{i(t + '.product')} /* {s['product']} */,\n" for t, s in targets.items())
lines.append(f"\t\t{i('productsGroup')} /* Products */ = {{\n\t\t\tisa = PBXGroup;\n\t\t\tchildren = (\n{prods}\t\t\t);\n"
             f"\t\t\tname = Products;\n\t\t\tsourceTree = \"<group>\";\n\t\t}};")
lines.append("/* End PBXGroup section */\n")

lines.append("/* Begin PBXNativeTarget section */")
for t, spec in targets.items():
    groups = "".join(f"\t\t\t\t{i('group.' + g)} /* {g} */,\n" for g in spec["groups"])
    lines.append(
        f"\t\t{i(t)} /* {t} */ = {{\n\t\t\tisa = PBXNativeTarget;\n"
        f"\t\t\tbuildConfigurationList = {i(t + '.configs')} /* Build configuration list for PBXNativeTarget \"{t}\" */;\n"
        f"\t\t\tbuildPhases = (\n\t\t\t\t{i(t + '.sources')} /* Sources */,\n\t\t\t\t{i(t + '.frameworks')} /* Frameworks */,\n"
        f"\t\t\t\t{i(t + '.resources')} /* Resources */,\n\t\t\t);\n\t\t\tbuildRules = (\n\t\t\t);\n\t\t\tdependencies = (\n\t\t\t);\n"
        f"\t\t\tfileSystemSynchronizedGroups = (\n{groups}\t\t\t);\n\t\t\tname = {t};\n\t\t\tpackageProductDependencies = (\n"
        f"\t\t\t\t{i(t + '.protobuf.product')} /* SwiftProtobuf */,\n\t\t\t);\n"
        f"\t\t\tproductName = {t};\n\t\t\tproductReference = {i(t + '.product')} /* {spec['product']} */;\n"
        f"\t\t\tproductType = {spec['product_type']};\n\t\t}};")
lines.append("/* End PBXNativeTarget section */\n")

target_list = "".join(f"\t\t\t\t{i(t)} /* {t} */,\n" for t in targets)
lines.append("/* Begin PBXProject section */")
lines.append(
    f"\t\t{i('project')} /* Project object */ = {{\n\t\t\tisa = PBXProject;\n"
    f"\t\t\tattributes = {{\n\t\t\t\tBuildIndependentTargetsInParallel = 1;\n\t\t\t\tLastSwiftUpdateCheck = 2600;\n\t\t\t\tLastUpgradeCheck = 2600;\n\t\t\t}};\n"
    f"\t\t\tbuildConfigurationList = {i('project.configs')} /* Build configuration list for PBXProject \"SubwaySaver\" */;\n"
    f"\t\t\tdevelopmentRegion = en;\n\t\t\thasScannedForEncodings = 0;\n\t\t\tknownRegions = (\n\t\t\t\ten,\n\t\t\t\tBase,\n\t\t\t);\n"
    f"\t\t\tmainGroup = {i('mainGroup')};\n\t\t\tminimizedProjectReferenceProxies = 1;\n"
    f"\t\t\tpackageReferences = (\n\t\t\t\t{i('package.protobuf')} /* XCRemoteSwiftPackageReference \"swift-protobuf\" */,\n\t\t\t);\n"
    f"\t\t\tpreferredProjectObjectVersion = 77;\n"
    f"\t\t\tproductRefGroup = {i('productsGroup')} /* Products */;\n\t\t\tprojectDirPath = \"\";\n\t\t\tprojectRoot = \"\";\n"
    f"\t\t\ttargets = (\n{target_list}\t\t\t);\n\t\t}};")
lines.append("/* End PBXProject section */\n")

lines.append("/* Begin PBXResourcesBuildPhase section */")
for t in targets:
    lines.append(f"\t\t{i(t + '.resources')} /* Resources */ = {{isa = PBXResourcesBuildPhase; buildActionMask = 2147483647; "
                 f"files = (); runOnlyForDeploymentPostprocessing = 0; }};")
lines.append("/* End PBXResourcesBuildPhase section */\n")

lines.append("/* Begin PBXSourcesBuildPhase section */")
for t in targets:
    lines.append(f"\t\t{i(t + '.sources')} /* Sources */ = {{isa = PBXSourcesBuildPhase; buildActionMask = 2147483647; "
                 f"files = (); runOnlyForDeploymentPostprocessing = 0; }};")
lines.append("/* End PBXSourcesBuildPhase section */\n")

lines.append("/* Begin XCBuildConfiguration section */")
for cfg, settings in project_settings.items():
    lines.append(f"\t\t{i('project.' + cfg)} /* {cfg} */ = {{\n\t\t\tisa = XCBuildConfiguration;\n\t\t\tbuildSettings = {{\n"
                 f"{settings_block(settings, 4)}\t\t\t}};\n\t\t\tname = {cfg};\n\t\t}};")
for t, spec in targets.items():
    for cfg in project_settings:
        lines.append(f"\t\t{i(t + '.' + cfg)} /* {cfg} */ = {{\n\t\t\tisa = XCBuildConfiguration;\n\t\t\tbuildSettings = {{\n"
                     f"{settings_block(spec['settings'], 4)}\t\t\t}};\n\t\t\tname = {cfg};\n\t\t}};")
lines.append("/* End XCBuildConfiguration section */\n")

lines.append("/* Begin XCConfigurationList section */")
for owner, label in [("project", 'PBXProject "SubwaySaver"')] + [(t, f'PBXNativeTarget "{t}"') for t in targets]:
    cfgs = "".join(f"\t\t\t\t{i(owner + '.' + c)} /* {c} */,\n" for c in project_settings)
    lines.append(f"\t\t{i(owner + '.configs')} /* Build configuration list for {label} */ = {{\n\t\t\tisa = XCConfigurationList;\n"
                 f"\t\t\tbuildConfigurations = (\n{cfgs}\t\t\t);\n\t\t\tdefaultConfigurationIsVisible = 0;\n"
                 f"\t\t\tdefaultConfigurationName = Release;\n\t\t}};")
lines.append("/* End XCConfigurationList section */\n")

lines.append("/* Begin XCRemoteSwiftPackageReference section */")
lines.append(f"\t\t{i('package.protobuf')} /* XCRemoteSwiftPackageReference \"swift-protobuf\" */ = {{\n\t\t\tisa = XCRemoteSwiftPackageReference;\n"
             f"\t\t\trepositoryURL = \"{PACKAGE_URL}\";\n\t\t\trequirement = {{\n\t\t\t\tkind = upToNextMajorVersion;\n"
             f"\t\t\t\tminimumVersion = {PACKAGE_MIN};\n\t\t\t}};\n\t\t}};")
lines.append("/* End XCRemoteSwiftPackageReference section */\n")

lines.append("/* Begin XCSwiftPackageProductDependency section */")
for t in targets:
    lines.append(f"\t\t{i(t + '.protobuf.product')} /* SwiftProtobuf */ = {{\n\t\t\tisa = XCSwiftPackageProductDependency;\n"
                 f"\t\t\tpackage = {i('package.protobuf')} /* XCRemoteSwiftPackageReference \"swift-protobuf\" */;\n"
                 f"\t\t\tproductName = SwiftProtobuf;\n\t\t}};")
lines.append("/* End XCSwiftPackageProductDependency section */")

lines += ["\t};", f"\trootObject = {i('project')} /* Project object */;", "}", ""]
OUT.parent.mkdir(parents=True, exist_ok=True)
OUT.write_text("\n".join(lines))
print(f"wrote {OUT} ({len(ids)} objects)")
