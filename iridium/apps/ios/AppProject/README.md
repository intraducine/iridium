The app project template owns native target/resource membership and build settings.
`ci/madeira-frontend.py project()` adds the enumerated app-owned Swift source set
and separately embedded console components. Main-target Swift file references do
not belong in this template. The helper target retains its explicit entry point.
The template is stored as an XML property list, accepted by Xcode and editable
with `plutil`/`plistlib` without brittle text substitutions.

Paths are relative to the documented `.build/madeira-frontend/app` staging layout,
not a saved DerivedData directory. Native include/library paths intentionally
refer to pinned build outputs beside that app tree. Metadata/ holds the owned app
Info.plist, extension Info.plist and app entitlements. Keep engine build recipes,
component receipts and runtime libraries out of this source template.
