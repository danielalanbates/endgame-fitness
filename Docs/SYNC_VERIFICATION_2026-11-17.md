# Drive sync follow-up
The first merged sync passed backend and Swift syntax checks but failed the full macOS build because CommunityView exceeded Swift's type-checking limit. Split its picker and selected section into smaller view properties, using the build-tested decomposition from feat/local-training-mobile without adopting that branch's product-flow changes.
The iOS runner pinned Xcode 16.2 while installed simulator runtimes belonged to newer SDKs. Use the runner's default Xcode and preserve build failure status without an automatic duplicate build.
Preserved newer GitHub auth/schema/deploy fixes where Drive copies were older. No live deployments or public releases were made by this follow-up.
