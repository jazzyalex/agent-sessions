# DeepSeek Harness Zstandard dependency

Agent Sessions uses the upstream Zstandard Swift package as an in-process
decoder for DeepSeek Harness `.jsonl.zstd` artifacts.

- Package: `https://github.com/facebook/zstd.git`
- Product: `libzstd`
- Pinned tag: `v1.5.7`
- Resolved source revision: `f8745da6ff1ad1e7bab384bd1f9d742439278e99`
- License: BSD License for Zstandard software, reproduced by the upstream
  `LICENSE` file.
- Architectures: the package builds the C target through Xcode for the
  application's supported macOS architectures; no runtime library lookup is
  used.
- Integration: exact Swift package requirement in
  `AgentSessions.xcodeproj/project.pbxproj`, with the resolved revision in
  `AgentSessions.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved`.

The decoder is linked in-process. This source never invokes Homebrew, a
`zstd` executable, `Process`, or `dlopen`/runtime library discovery.

## Update procedure

1. Review the upstream release tag and its `LICENSE`/notice files.
2. Resolve the exact tag with `xcodebuild -resolvePackageDependencies`.
3. Record the resulting revision, license evidence, and architecture/build
   result here and in the release evidence before changing the pin.
4. Run the complete decoder, fixture, build, and stable test gates.

This repository does not copy or modify upstream Zstandard source. The package
pin is the reproducible dependency boundary.
