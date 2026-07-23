# Changelog

## [0.149.0](https://github.com/GlueOps/codespaces/compare/v0.148.0...v0.149.0) (2026-07-23)


### Features

* update hashicorp/setup-packer to v3.4.0 #minor ([#528](https://github.com/GlueOps/codespaces/issues/528)) ([eab7f33](https://github.com/GlueOps/codespaces/commit/eab7f338caa489b2d30fbe35f40c7ce671404786))

## [0.148.0](https://github.com/GlueOps/codespaces/compare/v0.147.0...v0.148.0) (2026-07-11)


### Features

* disable VS Code Workspace Trust in the image ([86a5552](https://github.com/GlueOps/codespaces/commit/86a555259f8cadefa12afc2be3d62e49c25ace54))

## [0.147.0](https://github.com/GlueOps/codespaces/compare/v0.146.1...v0.147.0) (2026-07-11)


### Features

* pass code tunnel/serve-web through; harden socket probe ([a0769ed](https://github.com/GlueOps/codespaces/commit/a0769ed8a670c170da183d0b6a90907eb225d0a4))


### Bug Fixes

* make `code <file>` work in serve-web terminals ([93437d7](https://github.com/GlueOps/codespaces/commit/93437d7e57b723d332296081a6fcf07aaecde8ab))
* recover `code` from stale IPC socket after reconnect ([1731ce9](https://github.com/GlueOps/codespaces/commit/1731ce9c4b80d4a4ee281f620012c9d3f0f101c4))
* require the resolved `code` shim to be executable ([017e29f](https://github.com/GlueOps/codespaces/commit/017e29f032f4951373d9b3c21e620ebc83d666eb))
* route `code` to the newest live window socket (tmux fix) ([904829c](https://github.com/GlueOps/codespaces/commit/904829c8aebfb6971b20815ff21b6a9a3d3d52a2))

## [0.146.1](https://github.com/GlueOps/codespaces/compare/v0.146.0...v0.146.1) (2026-07-10)


### Miscellaneous Chores

* **main:** release 0.146.0 ([#517](https://github.com/GlueOps/codespaces/issues/517)) ([94fb1b1](https://github.com/GlueOps/codespaces/commit/94fb1b158804d24fd0455299cc6e125048a829e4))

## [0.146.0](https://github.com/GlueOps/codespaces/compare/v0.145.0...v0.146.0) (2026-07-10)


### Features

* update derailed/k9s to v0.51.0 #minor ([#514](https://github.com/GlueOps/codespaces/issues/514)) ([6a72a8c](https://github.com/GlueOps/codespaces/commit/6a72a8cb27d77d0e56743654b713b37ea03f0c6e))
* update hashicorp/setup-packer to v3.3.0 #minor ([#507](https://github.com/GlueOps/codespaces/issues/507)) ([7430c10](https://github.com/GlueOps/codespaces/commit/7430c10b48dfe8ee54e3419dc50bd29ffbbd9fdb))
* update k3d-io/k3d to v5.9.0 #minor ([#509](https://github.com/GlueOps/codespaces/issues/509)) ([c1fd943](https://github.com/GlueOps/codespaces/commit/c1fd943e8be68c35d30ec7f09a9819b985b04267))
* update kubernetes-sigs/kind to v0.32.0 #minor ([#510](https://github.com/GlueOps/codespaces/issues/510)) ([d8b5b82](https://github.com/GlueOps/codespaces/commit/d8b5b8201a386f1237553596646fa4acdce1a1dd))
* update vscode to launch with a dark profile theme by default ([#513](https://github.com/GlueOps/codespaces/issues/513)) ([edf1202](https://github.com/GlueOps/codespaces/commit/edf12023cb0501c60de09c88af6977f73242215e))


### Miscellaneous Chores

* **fallback:** update docker/login-action ([#506](https://github.com/GlueOps/codespaces/issues/506)) ([ec2ce6c](https://github.com/GlueOps/codespaces/commit/ec2ce6c7d8a804dc0752f746aef52a511925da87))
* **fallback:** update docker/login-action ([#511](https://github.com/GlueOps/codespaces/issues/511)) ([813f6dc](https://github.com/GlueOps/codespaces/commit/813f6dcecc7032ba418e657d9fccfcb613c16f1e))
* **fallback:** update docker/login-action ([#516](https://github.com/GlueOps/codespaces/issues/516)) ([8442e02](https://github.com/GlueOps/codespaces/commit/8442e02c4b1bd3a10ac8e215e2c0872cd24602f6))
* **patch:** update databus23/helm-diff to v3.15.8 #patch ([#512](https://github.com/GlueOps/codespaces/issues/512)) ([d8caa8e](https://github.com/GlueOps/codespaces/commit/d8caa8e155b04a685344de01d622be97c925daa0))
* **patch:** update hashicorp/packer to v1.15.4 #patch ([#486](https://github.com/GlueOps/codespaces/issues/486)) ([d18c92f](https://github.com/GlueOps/codespaces/commit/d18c92fd01a280498036ebb61ff22897535d93e4))

## [0.145.0](https://github.com/GlueOps/codespaces/compare/v0.144.0...v0.145.0) (2026-07-01)


### Features

* install claude code cli in devcontainer image ([#504](https://github.com/GlueOps/codespaces/issues/504)) ([bbb22df](https://github.com/GlueOps/codespaces/commit/bbb22df437ed62e195a8590bb84fe4805d984e9d))

## [0.144.0](https://github.com/GlueOps/codespaces/compare/v0.143.0...v0.144.0) (2026-07-01)


### Features

* install cloudflared in devcontainer image ([#503](https://github.com/GlueOps/codespaces/issues/503)) ([0329d3d](https://github.com/GlueOps/codespaces/commit/0329d3def8a936a00e48e9bca0e00686881f141f))
* update argoproj/argo-cd to v3.3.11 #minor ([#448](https://github.com/GlueOps/codespaces/issues/448)) ([5d3b5a0](https://github.com/GlueOps/codespaces/commit/5d3b5a0192a5f50455f930a989ba3b218b1ac5f4))
* update helm/helm to v3.20.2 #minor ([#438](https://github.com/GlueOps/codespaces/issues/438)) ([ee4ab40](https://github.com/GlueOps/codespaces/commit/ee4ab409d151ff3d58a0750712e8d1f113d41678))
* update kubernetes-sigs/krew to v0.5.0 #minor ([#498](https://github.com/GlueOps/codespaces/issues/498)) ([3042ced](https://github.com/GlueOps/codespaces/commit/3042ced619f6a03603087a724810c038db718d60))


### Miscellaneous Chores

* **fallback:** update actions/checkout ([#488](https://github.com/GlueOps/codespaces/issues/488)) ([6ffa0f5](https://github.com/GlueOps/codespaces/commit/6ffa0f52fa8f61954a2dc6278672097a433ac2ea))
* **fallback:** update devcontainers/ci ([#487](https://github.com/GlueOps/codespaces/issues/487)) ([3eee3a5](https://github.com/GlueOps/codespaces/commit/3eee3a5c22c4a7aeb7a7ae8b4d95592efa6bbe81))
* **fallback:** update glueops/github-workflows ([#499](https://github.com/GlueOps/codespaces/issues/499)) ([43882b4](https://github.com/GlueOps/codespaces/commit/43882b47f1da4137faa512f875b77fe03cc69730))


### Continuous Integration

* add release-please ([#501](https://github.com/GlueOps/codespaces/issues/501)) ([da6f1ed](https://github.com/GlueOps/codespaces/commit/da6f1ed37fdba1adb3b0c3cbb67a503e7fb350f0))
