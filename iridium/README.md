# Iridium app

The maintained iOS app lives in `apps/ios/App`, `MadeiraFrontend`, and
`RuntimeBridge`. It uses pinned engines from the root `vendor` directory.
The older Swift packages and embedded runtime remain for development and tests.

- [Build and install](../docs/actions-ipa.md)
- [Runtime boundaries](../docs/runtime-integration.md)
- [Using the app](docs/product-experience.md)
- [JIT setup](docs/builtin-stikjit-ios27.md)
- [Device testing](docs/manual-validation-runbook.md)

Use the root build command. The older `scripts/generate-project.sh` path does
not generate the complete current app.
