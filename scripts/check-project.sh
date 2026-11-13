#!/usr/bin/env bash
# Static checks for the hand-authored Xcode project. This does not replace
# xcodebuild; it catches missing files, dangling object IDs, an unshared scheme
# and wrong target settings before a macOS runner is spent.
set -euo pipefail
cd "$(dirname "$0")/.."

PY="${PYTHON:-}"
if [ -z "$PY" ]; then
  if command -v python3 >/dev/null 2>&1; then PY=python3; else PY=python; fi
fi

"$PY" - "$@" <<'PY'
import json
import re
import sys
import xml.etree.ElementTree as ET
from pathlib import Path

root = Path.cwd()
errors = []

required = [
    "FacetForge.xcodeproj/project.pbxproj",
    "FacetForge.xcodeproj/project.xcworkspace/contents.xcworkspacedata",
    "FacetForge.xcodeproj/xcshareddata/xcschemes/FacetForge.xcscheme",
    "FacetForge/FacetForgeApp.swift",
    "FacetForge/ContentView.swift",
    "FacetForge/AppIdentity.swift",
    "FacetForge/Info.plist",
    "FacetForge/DesignSystem/FFTokens.swift",
    "FacetForge/DesignSystem/FFComponents.swift",
    "FacetForge/DesignSystem/ComponentGalleryView.swift",
    "FacetForge/UI/FFAppShell.swift",
    "FacetForge/UI/FFLayoutLabView.swift",
    "FacetForge/UI/FFSceneSizePolicy.swift",
    "FacetForge/Math/FFMath.swift",
    "FacetForge/Math/FFMatrices.swift",
    "FacetForge/Math/FFGeometry.swift",
    "FacetForge/Math/FFCurves.swift",
    "FacetForge/Math/FFArcs.swift",
    "FacetForge/Math/FFPrimitives.swift",
    "FacetForge/Math/FFFreehand.swift",
    "FacetForge/Math/FFMeshes.swift",
    "FacetForge/Math/FFTessellation.swift",
    "FacetForge/Math/FFSurfaces.swift",
    "FacetForge/Math/FFRingProfiles.swift",
    "FacetForge/Math/FFSketchPlanes.swift",
    "FacetForge/Math/FFSketchConstraints.swift",
    "FacetForge/Math/FFSketchSystem.swift",
    "FacetForge/Render/FFCamera.swift",
    "FacetForge/Render/FFCameraNavigation.swift",
    "FacetForge/Units/FFUnits.swift",
    "FacetForge/Units/FFPrecision.swift",
    "FacetForge/Document/FFDocument.swift",
    "FacetForge/Document/FFDocumentStore.swift",
    "FacetForge/Document/FFDimensions.swift",
    "FacetForge/Math/FFSurfaceSweep.swift",
    "FacetForge/Document/FFSurfacePreview.swift",
    "FacetForge/UI/FFSurfacePreviewPanel.swift",
    "FacetForge/FileFormat/FFPJSONValue.swift",
    "FacetForge/FileFormat/FFPGeometryCodec.swift",
    "FacetForge/FileFormat/FFPManifest.swift",
    "FacetForge/FileFormat/FFPFormatMigration.swift",
    "FacetForge/FileFormat/FFPDocumentBundle.swift",
    "FacetForge/FileFormat/FFPThumbnail.swift",
    "FacetForge/FileFormat/FFOBJInterchange.swift",
    "FacetForge/Document/FFGrouping.swift",
    "FacetForge/Document/FFArrays.swift",
    "FacetForge/Document/FFMetadata.swift",
    "FacetForge/Document/FFDocumentTemplates.swift",
    "FacetForge/Document/FFLineChainTool.swift",
    "FacetForge/Document/FFArcTool.swift",
    "FacetForge/Document/FFDocumentPrimitives.swift",
    "FacetForge/Document/FFFreehandTool.swift",
    "FacetForge/Document/FFCurveEditing.swift",
    "FacetForge/Document/FFCurveCleanup.swift",
    "FacetForge/Document/FFOffset.swift",
    "FacetForge/Document/FFCornerTreatments.swift",
    "FacetForge/Document/FFCurveDiagnostics.swift",
    "FacetForge/Document/FFSketchPlaneTool.swift",
    "FacetForge/UI/FFTransformPanel.swift",
    "FacetForge/UI/FFArrayPanel.swift",
    "FacetForge/UI/FFMaterialPanel.swift",
    "FacetForge/UI/FFMetadataPanel.swift",
    "FacetForge/UI/FFLineChainOverlay.swift",
    "FacetForge/UI/FFFreehandOverlay.swift",
    "docs/format/ffp-1.0.schema.json",
    "docs/format/FFP-1.0.md",
    "docs/format/ffp-2.0.schema.json",
    "docs/format/FFP-2.0.md",
    "FacetForge/Render/FFMetalViewport.swift",
    "FacetForge/Render/FFSceneRendering.swift",
    "FacetForge/Render/FFDemoScene.swift",
    "FacetForge/Render/FFRealityViewport.swift",
    "FacetForge/Render/FFDisplayMode.swift",
    "FacetForge/Document/FFEditorSession.swift",
    "FacetForge/Document/FFLayer.swift",
    "FacetForge/Measure/FFMeasurement.swift",
    "FacetForge/UI/FFMeasurementOverlay.swift",
    "FacetForge/UI/FFTouchArbitration.swift",
    "FacetForge/UI/FFSnapHaptics.swift",
    "FacetForge/UI/FFRecoveryPrompt.swift",
    "FacetForge/UI/FFDocumentBrowserView.swift",
    "FacetForge/UI/FFLaunchFixtures.swift",
    "FacetForge/Document/FFEditJournal.swift",
    "FacetForge/Document/FFDocumentLibrary.swift",
    "FacetForge/Document/FFDocumentFile.swift",
    "FacetForge/Assets.xcassets/Contents.json",
    "FacetForge/Assets.xcassets/AccentColor.colorset/Contents.json",
    "FacetForgeTests/AppIdentityTests.swift",
    "FacetForgeTests/DesignSystemTests.swift",
    "FacetForgeTests/ComponentSnapshotTests.swift",
    "FacetForgeTests/LayoutSnapshotTests.swift",
    "FacetForgeTests/MathPropertyTests.swift",
    "FacetForgeTests/CurveKernelTests.swift",
    "FacetForgeTests/MeshKernelTests.swift",
    "FacetForgeTests/TessellationTests.swift",
    "FacetForgeTests/RenderTests.swift",
    "FacetForgeTests/CameraNavigationTests.swift",
    "FacetForgeTests/UnitsTests.swift",
    "FacetForgeTests/DocumentTests.swift",
    "FacetForgeTests/Phase13ViewportTests.swift",
    "FacetForgeTests/Phase18DisplayModeTests.swift",
    "FacetForgeTests/Phase19MeasurementTests.swift",
    "FacetForgeTests/Phase20LayerTests.swift",
    "FacetForgeTests/Phase24TouchTests.swift",
    "FacetForgeTests/Phase25FileFormatTests.swift",
    "FacetForgeTests/Phase26ReliabilityTests.swift",
    "FacetForgeTests/Phase27JournalTests.swift",
    "FacetForgeTests/Phase28LibraryTests.swift",
    "FacetForgeTests/Phase29InterchangeTests.swift",
    "FacetForgeTests/Phase30PrecisionTests.swift",
    "FacetForgeTests/Phase31LayerSetTests.swift",
    "FacetForgeTests/Phase32ObjectTreeTests.swift",
    "FacetForgeTests/Phase33GroupingTests.swift",
    "FacetForgeTests/Phase34ArrayTests.swift",
    "FacetForgeTests/Phase35MaterialTests.swift",
    "FacetForgeTests/Phase36MetadataTests.swift",
    "FacetForgeTests/Phase37TemplateTests.swift",
    "FacetForgeTests/Phase38FormatEvolutionTests.swift",
    "FacetForgeTests/Phase39LineChainTests.swift",
    "FacetForgeTests/Phase40ArcTests.swift",
    "FacetForgeTests/Phase41PrimitiveTests.swift",
    "FacetForgeTests/Phase42FreehandTests.swift",
    "FacetForgeTests/Phase43CurveEditingTests.swift",
    "FacetForgeTests/Phase44CurveCleanupTests.swift",
    "FacetForgeTests/Phase45OffsetTests.swift",
    "FacetForgeTests/Phase46CornerTests.swift",
    "FacetForgeTests/Phase47DiagnosticsTests.swift",
    "FacetForgeTests/Phase48ProjectionTests.swift",
    "FacetForgeTests/Phase49ProfileTests.swift",
    "FacetForgeTests/Phase50SketchPlaneTests.swift",
    "FacetForgeTests/Phase51SketchConstraintTests.swift",
    "FacetForgeTests/Phase52ConstraintSystemTests.swift",
    "FacetForgeTests/Phase53DrivingDimensionTests.swift",
    "FacetForgeTests/Phase54SurfacePreviewTests.swift",
    "FacetForgeTests/FFPJSONSchemaValidator.swift",
    "FacetForgeUITests/LaunchTests.swift",
    "FacetForgeUITests/GalleryTests.swift",
    "FacetForgeUITests/AdaptiveShellTests.swift",
    "FacetForgeUITests/CameraNavigationUITests.swift",
    "FacetForgeUITests/ViewportLayoutUITests.swift",
    "FacetForgeUITests/DisplayModeUITests.swift",
    "FacetForgeUITests/LayerPanelUITests.swift",
    "FacetForgeUITests/Phase24HitTargetUITests.swift",
    "FacetForgeUITests/Phase27RecoveryUITests.swift",
    "FacetForgeUITests/Phase28BrowserUITests.swift",
    "FacetForgeUITests/Phase31LayerSetUITests.swift",
    "FacetForgeUITests/Phase32ObjectTreeUITests.swift",
    "FacetForgeUITests/Phase33GroupUITests.swift",
    "FacetForgeUITests/Phase34ArrayUITests.swift",
    "FacetForgeUITests/Phase35MaterialUITests.swift",
    "FacetForgeUITests/Phase36MetadataUITests.swift",
    "FacetForgeUITests/Phase38MigrationUITests.swift",
    "FacetForgeUITests/Phase42FreehandUITests.swift",
    "FacetForgeUITests/Phase54SurfacePreviewUITests.swift",
]
for rel in required:
    if not (root / rel).exists():
        errors.append(f"missing {rel}")

project = root / "FacetForge.xcodeproj/project.pbxproj"
scheme = root / "FacetForge.xcodeproj/xcshareddata/xcschemes/FacetForge.xcscheme"
workspace = root / "FacetForge.xcodeproj/project.xcworkspace/contents.xcworkspacedata"

target_id = None
if project.exists():
    text = project.read_text(encoding="utf-8")
    if text.count("{") != text.count("}"):
        errors.append("project.pbxproj has unbalanced braces")
    if text.count('"') % 2:
        errors.append("project.pbxproj has an odd number of double quotes")
    if "rootObject =" not in text:
        errors.append("project.pbxproj has no rootObject")

    match = re.search(r"([0-9A-F]{24}) /\* FacetForge \*/ = \{\s*isa = PBXNativeTarget;", text)
    if not match:
        errors.append("no PBXNativeTarget named FacetForge")
    else:
        target_id = match.group(1)
        block = text[match.start():]
        block = block[: block.find("};") + 2]
        for token in (
            'productType = "com.apple.product-type.application";',
            "productReference = A10000000000000000000006",
        ):
            if token not in block:
                errors.append(f"FacetForge target is missing {token!r}")

    settings = [
        "PRODUCT_BUNDLE_IDENTIFIER = com.shahroodazerov.facetforge;",
        "IPHONEOS_DEPLOYMENT_TARGET = 26.0;",
        "TARGETED_DEVICE_FAMILY = 2;",
        "SWIFT_VERSION = 5.0;",
        "GENERATE_INFOPLIST_FILE = YES;",
        "GENERATE_INFOPLIST_FILE = NO;",
        "INFOPLIST_FILE = FacetForge/Info.plist;",
        "INFOPLIST_KEY_UILaunchScreen_Generation = YES;",
        "INFOPLIST_KEY_UIApplicationSceneManifest_Generation = YES;",
        'SUPPORTED_PLATFORMS = "iphoneos iphonesimulator";',
        "CODE_SIGN_STYLE = Automatic;",
    ]
    for token in settings:
        if token not in text:
            errors.append(f"project.pbxproj is missing {token!r}")

    for name, product in (("FacetForgeTests", "FacetForgeTests.xctest"), ("FacetForgeUITests", "FacetForgeUITests.xctest")):
        target = re.search(rf"([0-9A-F]{{24}}) /\* {name} \*/ = \{{\s*isa = PBXNativeTarget;", text)
        if not target:
            errors.append(f"no PBXNativeTarget named {name}")
        else:
            block = text[target.start():]
            block = block[: block.find("};") + 2]
            if product not in block:
                errors.append(f"{name} target does not produce {product}")

    for token in (
        "A10000000000000000000023 /* FFAppShell.swift in Sources */",
        "A10000000000000000000024 /* FFLayoutLabView.swift in Sources */",
        "A10000000000000000000025 /* FFSceneSizePolicy.swift in Sources */",
        "A1000000000000000000002B /* FFMath.swift in Sources */",
        "A1000000000000000000002C /* FFMatrices.swift in Sources */",
        "A1000000000000000000002D /* FFGeometry.swift in Sources */",
        "A1000000000000000000002F /* FFCurves.swift in Sources */",
        "A20000000000000000000017 /* CurveKernelTests.swift in Sources */",
        "A10000000000000000000031 /* FFMeshes.swift in Sources */",
        "A10000000000000000000033 /* FFTessellation.swift in Sources */",
        "A20000000000000000000019 /* MeshKernelTests.swift in Sources */",
        "A2000000000000000000001B /* TessellationTests.swift in Sources */",
        "A10000000000000000000035 /* FFCamera.swift in Sources */",
        "A10000000000000000000037 /* FFMetalViewport.swift in Sources */",
        "A1000000000000000000004A /* FFSceneRendering.swift in Sources */",
        "A1000000000000000000004C /* FFDemoScene.swift in Sources */",
        "A1000000000000000000004E /* FFRealityViewport.swift in Sources */",
        "A1000000000000000000003B /* FFCameraNavigation.swift in Sources */",
        "A1000000000000000000003E /* FFUnits.swift in Sources */",
        "A1000000000000000000008A /* FFPrecision.swift in Sources */",
        "A10000000000000000000046 /* FFDocument.swift in Sources */",
        "A10000000000000000000048 /* FFDocumentStore.swift in Sources */",
        "A1000000000000000000005C /* FFDisplayMode.swift in Sources */",
        "A1000000000000000000005E /* FFEditorSession.swift in Sources */",
        "A10000000000000000000060 /* FFMeasurement.swift in Sources */",
        "A10000000000000000000062 /* FFMeasurementOverlay.swift in Sources */",
        "A10000000000000000000065 /* FFLayer.swift in Sources */",
        "A1000000000000000000006C /* FFTouchArbitration.swift in Sources */",
        "A1000000000000000000006E /* FFSnapHaptics.swift in Sources */",
        "A1000000000000000000007B /* FFEditJournal.swift in Sources */",
        "A1000000000000000000007D /* FFRecoveryPrompt.swift in Sources */",
        "A1000000000000000000007F /* FFLaunchFixtures.swift in Sources */",
        "A10000000000000000000081 /* FFDocumentLibrary.swift in Sources */",
        "A10000000000000000000083 /* FFDocumentFile.swift in Sources */",
        "A10000000000000000000085 /* FFDocumentBrowserView.swift in Sources */",
        "A20000000000000000000023 /* DocumentTests.swift in Sources */",
        "A20000000000000000000025 /* Phase13ViewportTests.swift in Sources */",
        "A2000000000000000000001D /* RenderTests.swift in Sources */",
        "A2000000000000000000001F /* CameraNavigationTests.swift in Sources */",
        "A20000000000000000000021 /* UnitsTests.swift in Sources */",
        "A20000000000000000000013 /* LayoutSnapshotTests.swift in Sources */",
        "A20000000000000000000015 /* MathPropertyTests.swift in Sources */",
        "A30000000000000000000011 /* AdaptiveShellTests.swift in Sources */",
        "A30000000000000000000013 /* CameraNavigationUITests.swift in Sources */",
        "A30000000000000000000015 /* ViewportLayoutUITests.swift in Sources */",
        "A2000000000000000000002F /* Phase18DisplayModeTests.swift in Sources */",
        "A20000000000000000000031 /* Phase19MeasurementTests.swift in Sources */",
        "A20000000000000000000033 /* Phase20LayerTests.swift in Sources */",
        "A3000000000000000000001D /* DisplayModeUITests.swift in Sources */",
        "A3000000000000000000001F /* LayerPanelUITests.swift in Sources */",
        "A10000000000000000000071 /* FFPJSONValue.swift in Sources */",
        "A10000000000000000000073 /* FFPGeometryCodec.swift in Sources */",
        "A10000000000000000000075 /* FFPManifest.swift in Sources */",
        "A100000000000000000000A1 /* FFPFormatMigration.swift in Sources */",
        "A100000000000000000000A3 /* FFLineChainTool.swift in Sources */",
        "A100000000000000000000A5 /* FFLineChainOverlay.swift in Sources */",
        "A100000000000000000000A7 /* FFArcs.swift in Sources */",
        "A100000000000000000000A9 /* FFArcTool.swift in Sources */",
        "A100000000000000000000AB /* FFPrimitives.swift in Sources */",
        "A100000000000000000000AD /* FFDocumentPrimitives.swift in Sources */",
        "A100000000000000000000B2 /* FFFreehand.swift in Sources */",
        "A100000000000000000000B4 /* FFFreehandTool.swift in Sources */",
        "A100000000000000000000B6 /* FFFreehandOverlay.swift in Sources */",
        "A100000000000000000000B8 /* FFCurveEditing.swift in Sources */",
        "A100000000000000000000BA /* FFCurveCleanup.swift in Sources */",
        "A100000000000000000000BC /* FFOffset.swift in Sources */",
        "A100000000000000000000BE /* FFCornerTreatments.swift in Sources */",
        "A10000000000000000000077 /* FFPDocumentBundle.swift in Sources */",
        "A10000000000000000000079 /* FFPThumbnail.swift in Sources */",
        "A10000000000000000000087 /* FFOBJInterchange.swift in Sources */",
        "A1000000000000000000008B /* FFObjectTree.swift in Sources */",
        "A1000000000000000000008D /* FFObjectTreePanel.swift in Sources */",
        "A1000000000000000000008F /* FFGrouping.swift in Sources */",
        "A10000000000000000000091 /* FFTransformPanel.swift in Sources */",
        "A10000000000000000000093 /* FFArrays.swift in Sources */",
        "A10000000000000000000095 /* FFArrayPanel.swift in Sources */",
        "A2000000000000000000003C /* FFPJSONSchemaValidator.swift in Sources */",
        "A2000000000000000000003E /* Phase25FileFormatTests.swift in Sources */",
        "A2000000000000000000005B /* Phase38FormatEvolutionTests.swift in Sources */",
        "A2000000000000000000005D /* Phase39LineChainTests.swift in Sources */",
        "A2000000000000000000005F /* Phase40ArcTests.swift in Sources */",
        "A20000000000000000000061 /* Phase41PrimitiveTests.swift in Sources */",
        "A20000000000000000000064 /* Phase42FreehandTests.swift in Sources */",
        "A20000000000000000000066 /* Phase43CurveEditingTests.swift in Sources */",
        "A20000000000000000000068 /* Phase44CurveCleanupTests.swift in Sources */",
        "A2000000000000000000006A /* Phase45OffsetTests.swift in Sources */",
        "A2000000000000000000006C /* Phase46CornerTests.swift in Sources */",
        "A100000000000000000000C1 /* FFCurveDiagnostics.swift in Sources */",
        "A20000000000000000000070 /* Phase47DiagnosticsTests.swift in Sources */",
        "A100000000000000000000C3 /* FFSurfaces.swift in Sources */",
        "A100000000000000000000C5 /* FFRingProfiles.swift in Sources */",
        "A100000000000000000000CB /* FFSketchConstraints.swift in Sources */",
        "A100000000000000000000CD /* FFSketchSystem.swift in Sources */",
        "A100000000000000000000CF /* FFDimensions.swift in Sources */",
        "A20000000000000000000072 /* Phase48ProjectionTests.swift in Sources */",
        "A20000000000000000000074 /* Phase49ProfileTests.swift in Sources */",
        "A20000000000000000000078 /* Phase51SketchConstraintTests.swift in Sources */",
        "A2000000000000000000007A /* Phase52ConstraintSystemTests.swift in Sources */",
        "A2000000000000000000007C /* Phase53DrivingDimensionTests.swift in Sources */",
        "A100000000000000000000D1 /* FFSurfaceSweep.swift in Sources */",
        "A100000000000000000000D3 /* FFSurfacePreview.swift in Sources */",
        "A100000000000000000000D5 /* FFSurfacePreviewPanel.swift in Sources */",
        "A2000000000000000000007E /* Phase54SurfacePreviewTests.swift in Sources */",
        "A3000000000000000000003C /* Phase54SurfacePreviewUITests.swift in Sources */",
        "A20000000000000000000040 /* Phase26ReliabilityTests.swift in Sources */",
        "A20000000000000000000043 /* Phase27JournalTests.swift in Sources */",
        "A20000000000000000000047 /* Phase28LibraryTests.swift in Sources */",
        "A20000000000000000000049 /* Phase29InterchangeTests.swift in Sources */",
        "A2000000000000000000004C /* Phase30PrecisionTests.swift in Sources */",
        "A2000000000000000000004E /* Phase31LayerSetTests.swift in Sources */",
        "A2000000000000000000004F /* Phase32ObjectTreeTests.swift in Sources */",
        "A20000000000000000000051 /* Phase33GroupingTests.swift in Sources */",
        "A20000000000000000000053 /* Phase34ArrayTests.swift in Sources */",
        "A2000000000000000000003B /* Phase24TouchTests.swift in Sources */",
        "A30000000000000000000025 /* Phase24HitTargetUITests.swift in Sources */",
        "A30000000000000000000027 /* Phase27RecoveryUITests.swift in Sources */",
        "A30000000000000000000029 /* Phase28BrowserUITests.swift in Sources */",
        "A3000000000000000000002B /* Phase31LayerSetUITests.swift in Sources */",
        "A3000000000000000000002D /* Phase32ObjectTreeUITests.swift in Sources */",
        "A3000000000000000000002F /* Phase33GroupUITests.swift in Sources */",
        "A30000000000000000000031 /* Phase34ArrayUITests.swift in Sources */",
        "A30000000000000000000037 /* Phase38MigrationUITests.swift in Sources */",
        "A30000000000000000000039 /* Phase42FreehandUITests.swift in Sources */",
        "PRODUCT_BUNDLE_IDENTIFIER = com.shahroodazerov.facetforge.tests;",
        "PRODUCT_BUNDLE_IDENTIFIER = com.shahroodazerov.facetforge.uitests;",
        'TEST_HOST = "$(BUILT_PRODUCTS_DIR)/FacetForge.app/FacetForge";',
        "TEST_TARGET_NAME = FacetForge;",
        'productType = "com.apple.product-type.bundle.unit-test";',
        'productType = "com.apple.product-type.bundle.ui-testing";',
    ):
        if token not in text:
            errors.append(f"project.pbxproj is missing {token!r}")

    defs = set(re.findall(r"^\s*([0-9A-F]{24})(?: /\*.*?\*/)? = \{", text, re.M))
    refs = set(re.findall(r"\b([0-9A-F]{24})\b", text))
    dangling = sorted(refs - defs)
    if dangling:
        errors.append("project.pbxproj references undefined object IDs: " + ", ".join(dangling))

    root_match = re.search(r"rootObject = ([0-9A-F]{24})", text)
    if root_match and root_match.group(1) not in defs:
        errors.append("project.pbxproj rootObject is not defined")

if scheme.exists():
    try:
        tree = ET.parse(scheme)
    except ET.ParseError as exc:
        errors.append(f"scheme is not valid XML: {exc}")
    else:
        refs = [e for e in tree.iter("BuildableReference")]
        if not refs:
            errors.append("scheme has no BuildableReference")
        else:
            if target_id and not any(e.get("BlueprintIdentifier") == target_id for e in refs):
                errors.append("scheme BlueprintIdentifier does not match the FacetForge target")
            if not any(e.get("BuildableName") == "FacetForge.app" for e in refs):
                errors.append('scheme BuildableName is not "FacetForge.app"')
            if not any(e.get("ReferencedContainer") == "container:FacetForge.xcodeproj" for e in refs):
                errors.append("scheme does not reference container:FacetForge.xcodeproj")

        testables = [e for e in tree.iter("TestableReference")]
        testable_names = {
            e.find("BuildableReference").get("BuildableName")
            for e in testables
            if e.find("BuildableReference") is not None
        }
        for product in ("FacetForgeTests.xctest", "FacetForgeUITests.xctest"):
            if product not in testable_names:
                errors.append(f"scheme TestAction does not include {product}")

if workspace.exists():
    try:
        ET.parse(workspace)
    except ET.ParseError as exc:
        errors.append(f"workspace is not valid XML: {exc}")

for rel in (
    "FacetForge/Assets.xcassets/Contents.json",
    "FacetForge/Assets.xcassets/AccentColor.colorset/Contents.json",
    "docs/format/ffp-1.0.schema.json",
    "docs/format/ffp-2.0.schema.json",
):
    path = root / rel
    if path.exists():
        try:
            json.loads(path.read_text(encoding="utf-8"))
        except Exception as exc:
            errors.append(f"{rel} is not valid JSON: {exc}")

app = root / "FacetForge/FacetForgeApp.swift"
content = root / "FacetForge/ContentView.swift"
if app.exists() and "@main" not in app.read_text(encoding="utf-8"):
    errors.append("FacetForgeApp.swift has no @main entry point")
if content.exists() and "struct ContentView" not in content.read_text(encoding="utf-8"):
    errors.append("ContentView.swift has no ContentView type")

if errors:
    print(f"project check: FAIL — {len(errors)} problem(s)")
    for e in errors:
        print("FAIL:", e)
    sys.exit(1)

print("project check: PASS — FacetForge.xcodeproj, shared scheme, app target")
PY
