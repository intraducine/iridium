# MoltenVK and shader dependency notices

The media SDK uses the iPhone MoltenVK 1.2.9 library from Vulkan SDK
1.3.283.0. Its object SHA-256 is
`52a9140c04f2366e83b6693ae3e612dcb84a0412534495776efb16530b6403a8`.
The SDK VERSIONS.txt identifies source commit
`bf097edc74ec3b6dfafdcd5a38d3ce14b11952d6`.

The license files here are copied unchanged from the revisions below.
Dependency revisions come from MoltenVK's ExternalRevisions files and
glslang's known_good.json. Tool and header sources are included for
rebuilding; inclusion does not mean every dependency is linked.
The exact source archive digests are pinned in ci/moltenvk-source-inputs.json.

- [MoltenVK](https://github.com/KhronosGroup/MoltenVK/tree/bf097edc74ec3b6dfafdcd5a38d3ce14b11952d6): `bf097edc74ec3b6dfafdcd5a38d3ce14b11952d6`.
- [SPIRV-Cross](https://github.com/KhronosGroup/SPIRV-Cross/tree/84cdc3b68e5ef5a15ecfacda77c61f24a9080cf9): `84cdc3b68e5ef5a15ecfacda77c61f24a9080cf9`.
- [Volk](https://github.com/zeux/volk/tree/3a8068a57417940cf2bf9d837a7bb60d015ca2f1): `3a8068a57417940cf2bf9d837a7bb60d015ca2f1`.
- [Vulkan-Headers](https://github.com/KhronosGroup/Vulkan-Headers/tree/eaa319dade959cb61ed2229c8ea42e307cc8f8b3): `eaa319dade959cb61ed2229c8ea42e307cc8f8b3`.
- [Vulkan-Tools](https://github.com/KhronosGroup/Vulkan-Tools/tree/09f5cc6b0758a05ccd6bcde1342256c15c76670e): `09f5cc6b0758a05ccd6bcde1342256c15c76670e`.
- [cereal](https://github.com/USCiLab/cereal/tree/51cbda5f30e56c801c07fe3d3aba5d7fb9e6cca4): `51cbda5f30e56c801c07fe3d3aba5d7fb9e6cca4`.
- [glslang](https://github.com/KhronosGroup/glslang/tree/e8dd0b6903b34f1879520b444634c75ea2deedf5): `e8dd0b6903b34f1879520b444634c75ea2deedf5`.
- [SPIRV-Tools](https://github.com/KhronosGroup/SPIRV-Tools/tree/dd4b663e13c07fea4fbb3f70c1c91c86731099f7): `dd4b663e13c07fea4fbb3f70c1c91c86731099f7`.
- [SPIRV-Headers](https://github.com/KhronosGroup/SPIRV-Headers/tree/4f7b471f1a66b6d06462cd4ba57628cc0cd087d7): `4f7b471f1a66b6d06462cd4ba57628cc0cd087d7`.
