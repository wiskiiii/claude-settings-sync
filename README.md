# claude-settings-sync

通过 WebDAV 在多台机器之间同步 Claude Code 的 `~/.claude/settings.json`。单个 bash 脚本，不需要安装。

## 用法

上传本机配置：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/wiskiiii/claude-settings-sync/main/claude-sync.sh) upload --url <WebDAV 目录> --user <用户名> --pass <密码>
```

下载到本机：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/wiskiiii/claude-settings-sync/main/claude-sync.sh) download --url <WebDAV 目录> --user <用户名> --pass <密码>
```

`--url` 是 WebDAV 上的一个目录，例如 `https://dav.example.com/dav/backup`。配置保存为该目录下的 `claude-settings.json`，目录不存在时会尝试创建。

依赖：`bash`、`curl`、`jq`、`diff`。macOS 15 及以上自带 jq；Linux 可能需要先安装 jq。

## 行为

- **上传**：去掉黑名单字段，列出被排除的字段名，显示与远端的差异，确认后上传。
- **下载**：以远端内容为准写入本机，本机的黑名单字段保持原值；本机有而远端没有的其他字段会被删除。显示差异，确认后写入，原文件备份为 `settings.json.bak`（只保留前一版）。
- 内容没有变化时直接退出。

## 黑名单

默认：

```
model effortLevel modelSettings enabledPlugins extraKnownMarketplaces hooks
```

在脚本顶部的 `BLACKLIST` 里修改，用空格或换行分隔：

- 顶层键直接写，如 `theme`
- 嵌套键写成 `父键.子键`，如 `env.ANTHROPIC_API_KEY`
- `*` 匹配任意字符，如 `env.ANTHROPIC_*`

## 注意

- 密码写在命令里，会留在 shell 历史中。
- 凭据通过 stdin 传给 curl，不出现在 curl 的进程参数里。
