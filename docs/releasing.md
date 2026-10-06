# 发布 Framecho

维护者发布流程。普通用户和贡献者不需要阅读本文档。

发布工具位于 `cmd/framecho-release`，发布目标为 `helson-lin/Screendrop`。完整流程需要 Go、`create-dmg`、已登录的 `gh`、Xcode、Developer ID Application 证书、Sparkle 签名密钥，以及名为 `framecho-notary` 的公证凭据配置。

```bash
brew install create-dmg
```

首次发布前，将公证凭据保存到钥匙串：

```bash
xcrun notarytool store-credentials framecho-notary --apple-id <apple-id> --team-id 64S5F787T9
```

示例：在 0.41.0（build 44）之后发布下一版：

```bash
go run ./cmd/framecho-release -build -yes -set-version 0.41.1 -set-build 45 -notes-file /path/to/release-notes.txt
```

工具依次完成：运行与 CI 相同的检查并确认该提交的 CI 已通过 → 写入并提交版本号 → 归档 → Developer ID 签名导出 → 公证并附加票据 → 生成 DMG 并做 Sparkle 签名 → 推送提交 → 创建 GitHub Release → 更新并推送 `appcast.xml`。

- 任一检查失败或该提交的 CI 失败时，工具会在构建前停止。`-skip-checks` 可跳过这一步，仅限紧急情况。
- 更新说明文件每行一条；每次发布递增 build 号，并先提交待发布的代码。
- 签名偶尔会因 Apple 时间戳服务暂时不可用而失败。归档和导出遇到这类错误会自动重试，最多 3 次，间隔 20 秒、40 秒；证书缺失等其他签名错误会立即停止，并在报错开头列出 codesign 的错误行。
- 不加 `-build` 时，工具直接打包已导出到 `~/Downloads/Framecho.app` 的应用。

## 签名密钥

Sparkle 的 EdDSA 私钥保存在维护者钥匙串的 `com.jarinhe.Framecho` 账户中。公证凭据和私钥不要提交到仓库，并请安全备份签名密钥，否则已安装的版本将无法收到可信更新。备份命令：

```bash
generate_keys --account com.jarinhe.Framecho -x <file>
```
