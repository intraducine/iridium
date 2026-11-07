The XML project template owns targets, resources, and build settings.
`ci/madeira-frontend.py project()` adds main-target Swift files and console
components. Keep only the helper's explicit entry point in the template.

Paths use `.build/madeira-frontend/app`, not a developer's DerivedData directory.
`Metadata/` owns app/extension Info.plists and entitlements. Engine recipes,
receipts, and binaries stay outside this template.

App and helper marketing versions are 0.3.0. `project()` applies that version to
every build configuration, including the generated memory helper. CI supplies
the unique build number. Keep `iridium/apps/ios/project.yml` and the generator's
version in step with this template. Check the final app and both helper plists.
