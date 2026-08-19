# PR Review Bot（headless agent）

自动监听 GitHub 仓库中请求指定 reviewer 审查的 PR，启动一个 headless agent session 以你配置的
模型完成代码审查。**agent harness 可配置**：`dsh`（DeepSeek Harness）或 `claude`（Claude Code
的 `claude -p` 无头模式），可全局设定，也可按仓库分别指定，并通过 GitHub API 把 review
（含 inline comments）贴回 PR。审查基于 **git worktree**——同一时间多个 PR 可并行 review，
互不干扰。

## 目录结构

```
pr-review-bot/
├── config.json        # 所有可配置项（不在 git 版本控制内）
├── config.example.json # 可移植配置模板
├── poll.sh            # 核心逻辑：发现候选 PR -> 启动 headless review session（timer 每 1 分钟调用）
├── run-now.sh         # 手动控制：立即轮询 / 手动 review 某个 PR / 查看状态
├── status.sh          # 查看当前状态（正在 review 哪些 PR、历史、等待队列）
├── systemd/           # systemd 用户级 unit 文件副本（service + timer，安装见下文「调度」）
├── git/               # 每个仓库一个 mirror clone（内部实现，勿手改）
├── worktrees/         # 每个 PR 一个 worktree（内部实现，审查完自动清理）
├── logs/              # 每个 review session 的完整日志 + 生成的 prompt
└── state/             # 去重状态、合并后的生效配置、模型 patch、PID、上次轮询时间
```

## 配置（config.json）

顶层字段是**全局配置**；`repos[]` 里的每个仓库条目可单独覆盖（override）这些值；
未覆盖的字段自动回落到全局值。合并结果保存在 `state/effective.json`。

```jsonc
{
  "reviewer": "your-github-username",   // 全局默认：监听谁被请求 review
  "poll_interval_minutes": 5,           // 轮询频率（timer 每分钟唤醒，脚本按此节流）
  "max_sessions_per_poll": 2,           // 每轮最多新开几个 review session
  "max_concurrent_sessions": 4,         // 同时最多允许几个 session 在跑（跨轮次的总量上限）
  "mention_window_hours": 24,           // 只关注最近 N 小时内的 @mention 评论
  "harness": "claude",                  // 全局默认 harness："claude" 或 "dsh"
  "model": {                            // 全局默认模型
    "provider": "",                     // claude 忽略此字段，留空即可；dsh 必填
    "model": "opus",                    // claude：别名或完整 id；dsh：provider 下的模型名
    "reasoningEffort": "high"
  },
  "claude": {                           // 仅 harness=claude 时有效，且**只能写在顶层**
    "bin": "",                          // "" = 自动探测 PATH 上的 claude；也可写绝对路径
    "config_dir": "~/.claude-sk"        // "" = claude 默认的 ~/.claude；见下文「claude 的 profile」
  },
  "session_env": {                      // 注入到 review session 进程的环境变量（值必须单行）
    "HTTPS_PROXY": "http://127.0.0.1:8889",   // 本机网络下模型 API 只能走本地代理，见下文
    "NO_PROXY": "localhost,127.0.0.1,::1",
    "SSL_CERT_FILE": "/etc/ssl/certs/ca-certificates.crt"
  },
  "gh": {
    "token_env": "",                    // 可选：读哪个环境变量作为 GitHub token
    "token": "",                        // 可选：直接写 token（优先级：token_env > token > gh keyring）
    "base_url": "https://github.com"    // GitHub Enterprise 可改
  },
  "custom_prompt": "<全局默认审查指令>",
  "git_dir": "git",                     // mirror 存放目录（相对本目录或绝对路径）
  "worktree_base": "worktrees",         // worktree 根目录
  "repos": [
    { "repo": "org/repo-a", "reviewer": "reviewer-a" },          // 只覆盖 reviewer
    { "repo": "org/repo-b",                                        // 其余全部用全局默认
      "harness": "dsh",                                            // 这个仓库改用 DeepSeek Harness
      "model": { "provider": "opencode-go", "model": "deepseek-v4-flash", "reasoningEffort": "max" },
      "custom_prompt": "Focus on security..." }                    // 仓库级 harness / 模型 / 审查指令
  ]
}
```

> 可覆盖的字段：`harness`、`reviewer`、`model.provider`、`model.model`、`model.reasoningEffort`、`custom_prompt`。

> `config.json` 位于本目录，而本目录不在任何 git 仓库内，因此不会被提交；目录内 `.gitignore`
> 也把 `config.json`、`state/`、`logs/`、`git/`、`worktrees/` 都忽略了，即使整个目录将来被
> 纳入版本控制也安全。

## Harness（dsh / claude）

`harness` 决定用哪个 agent 跑这次 review。两者读的是同一份 prompt、同一套 worktree 流程，
只是启动方式与模型字段的含义不同：

| | `dsh`（默认） | `claude` |
|---|---|---|
| 启动 | `node --expose-internals <dsh bin.js> --profile headless --patch <model-patch>` | `claude -p --permission-mode bypassPermissions --output-format json` |
| prompt 传递 | 命令行位置参数 | stdin（不受命令行长度限制） |
| `model.provider` | 必填，写进 `state/model-patch-<repo>.yml` | **忽略，请留空** |
| `model.model` | provider 下的模型名，如 `deepseek-v4-flash` | `--model` 的值：别名（`opus` / `sonnet` / `fable`）或完整 id |
| `model.reasoningEffort` | 写进 model patch | `--effort`，仅接受 `low` / `medium` / `high` / `xhigh` / `max`（其它值会告警并忽略） |
| 可执行文件 | `NODE` + `DSH_BIN` | `CLAUDE_BIN`（默认自动探测 `command -v claude`） |
| session 日志 | 纯文本，结束时一次性写入 | 单个 JSON 对象（含 `is_error` / `result` / `session_id` / `usage`） |

用 `claude` 的前置条件：

1. 本机装好 `claude` 并已登录（`claude auth` 或订阅登录均可）——bot 直接复用该登录态，
   不需要额外配 API key。用 `echo hi | claude -p` 验证一次即可。
2. review session 是**非交互**的，所以用 `--permission-mode bypassPermissions`，
   否则 agent 会卡在工具授权确认上。这与 dsh headless 的信任级别一致，但也意味着 agent
   在读取外部贡献者的 PR 内容时拥有完整工具权限（见下方安全提示）。
3. mirror 与 worktree 目录在 cwd 之外，已通过 `--add-dir` 显式放行。
4. `model.provider` 对 claude 无意义，**请留空**：它会出现在 PR 上那条"正在 review"评论里
   （留空时只显示模型名，不显示 `provider/`）。从 claude 切回 dsh 时记得把 provider 填回去。

### claude 的 profile（`claude.config_dir`）——容易踩的坑

如果你平时用的是 `claude-sk` 这类命令，先确认它到底是什么：

```bash
type claude-sk
# claude-sk is an alias for CLAUDE_CONFIG_DIR="$HOME/.claude-sk" claude
```

多数情况下它是一个 **shell alias**：同一个 `claude` 可执行文件，只是换了 `CLAUDE_CONFIG_DIR`
（即换了一套登录态 / 账号 / 历史）。这带来两个后果：

1. **alias 在脚本里不存在**。systemd 与 `poll.sh` 都不是交互式 shell，不会读 `.zshrc`，
   所以 bot 无法"运行 claude-sk"——只能运行真正的可执行文件 `claude`，再自己把 profile
   通过 `CLAUDE_CONFIG_DIR` 传进去。这正是 `claude.config_dir` 的作用。
2. **默认 profile 往往没登录**。`~/.claude` 里可能根本没有 `.credentials.json`，
   而 `~/.claude-sk` 里才有。此时不配 `config_dir`，session 会直接因为找不到配置而失败。

所以：把 `claude.config_dir` 指向**真正登录了的那个目录**（对应 alias 里的值）。校验方式：

```bash
./status.sh | grep -A1 '^Claude'
#   Claude  : /home/deck/.local/bin/claude
#             profile /home/deck/.claude-sk — logged in
```

优先级：环境变量 `CLAUDE_BIN` / `CLAUDE_CONFIG_DIR` > `config.json` 的 `claude.*` > 自动探测。
`bin` 写成不带斜线的名字时会先用 `command -v` 解析成绝对路径；写成 alias 名字（如 `claude-sk`）
是**无效**的——脚本无法执行 alias，请改用 `bin` + `config_dir` 的组合。
启动前会做预检：`config_dir` 不存在直接 FATAL（不会在 PR 上留下任何评论）；目录存在但没有
`.credentials.json` 且没有 `ANTHROPIC_API_KEY` 时打 WARNING。

> `claude` 这个配置块是**机器级**的，只能写在顶层；写进 `repos[]` 会被忽略（poll.log 会告警）。
> 另外注意 bot 与你的交互式会话共用同一个 profile 目录，session 历史会写进同一个 `projects/` 下。

> **安全提示**：无论哪个 harness，agent 都在拥有 GitHub 写权限 token 的情况下读取
> 攻击者可控的 PR 内容（diff、源码、PR 描述），存在 prompt injection 风险。已做的收敛：
>
> - `claude` session 的 cwd 是 `worktrees/<owner>-<repo>/`，**不是** bot 目录，
>   `config.json` 与 `logs/prompt-*.txt` 不在它的工作目录里；
> - session 继承的 git 凭据被收窄到**当前这个仓库**
>   （`http.<base>/<owner>/<repo>.git.extraheader`），用它访问同一 host 上的其它私有仓库会被拒；
> - review 的 JSON payload 写在 worktree 目录内，不落在 bot 的 `state/` 里。
>
> 仍建议把 token 换成仅对目标仓库开放 `pull_requests: read/write` 的 fine-grained token，
> 并考虑把 session 放进容器里跑（`bypassPermissions` 意味着 agent 在容器外拥有完整工具权限）。
> 另外 `logs/` 下的 prompt 与 session 日志包含 PR 的完整内容，按仓库敏感度决定是否定期清理。

切换后无需改任何脚本，只改 `config.json` 里的 `harness` 字段再跑一次 `./status.sh`
确认生效（会打印每个仓库的 harness）。

## 常用操作

查看当前状态（正在 review 哪些 PR、进行中/已完成/失败、等待队列）：

```bash
./status.sh          # 或 ./run-now.sh status
```

立即轮询一次（绕过间隔）：

```bash
./run-now.sh
```

（若此刻 timer 正在轮询，`./run-now.sh` 会等最多 60s 拿锁，而不是直接放弃；
手动指定单个 PR 的用法不做发现、不抢锁，随时可用。）

手动 review 某个 PR：

```bash
./run-now.sh 261                 # 第一个仓库（config.repos[0]）的 PR 261
./run-now.sh org/repo-a 42       # 指定仓库的 PR 42
```

只发现不动手：

```bash
DRY_RUN=1 ./run-now.sh
```

查看单个 review session 的完整过程：`tail -f logs/session-pr-*.log`

注意：headless review 会话是**独立进程**，既不会出现在 DSH Web GUI 的会话列表里
（GUI 只显示在 `dsh web` 里创建的会话），也不会出现在 `claude agents` 里。review 的最终
结果是贴在 GitHub PR 上的 review；过程日志在 `logs/` 下：`dsh` 的日志在会话期间通常是空的、
结束后一次性写入，`claude` 的日志是结束时写入的单个 JSON 对象。

## 工作原理

1. **发现**：每个仓库用 GitHub Search GraphQL 查 `review-requested:<该仓库的 reviewer>` 的
   open PR（**分页**拉取，不再被 `first: 100` 截断）；另外扫描最近 N 小时内的 issue/PR
   评论中 `@<reviewer>` 的提及（已处理过的评论 id 会跳过，过期条目自动清理）。
2. **去重与 re-request**：`state.json` 记录已处理/已 review 的 PR（含当时的 head_sha）与评论 id，
   避免重复触发。如果某个 PR 之后又被 re-request review，仅当**内容有变化**时才重新审查：
   PR head 出现了新 commit，或之前的 review 已被 dismiss；否则跳过。
   **review 进行中若 PR 出现新 commit，poller 会立即终止进行中的 session，并在同一轮
   为新 commit 重新开启 review**（发现延迟 ≤ poll_interval_minutes，可调小以获得更快的响应）。
   终止时按**进程组**发信号（session 用 `setsid` 启动，自成进程组），先 SIGTERM、约 5s 后
   SIGKILL，确保它派生的 git/gh 子进程不残留、不继续写同一个 worktree；确认进程真正退出后
   才重开新 session。若某轮拿不到 PR 当前 head（GitHub 临时报错），该 PR 本轮跳过，不会被
   误判为"有新 commit"而白跑一次 review。
3. **审查**：每个新 PR 启动一个 headless session（harness 见上文），prompt 指引 agent：
   在对应仓库的 git worktree 里拉取该 PR 的 head，`git diff` 对比 base 分支，逐文件阅读，
   按 custom prompt 审计，最后用 `gh api .../pulls/N/reviews` 一次性提交 review
   （inline comments 优先）。结果判定：**没有 blocking 问题就 APPROVE**（所有建议/小问题一律
   作为 inline comments 挂在 approve 上，不阻塞）；有阻塞问题才 REQUEST_CHANGES；
   拿不准/草稿阶段用 COMMENT。
4. **清理**：session 结束后自动移除 worktree，多个 PR 并行互不冲突。
   并发上限由 `max_concurrent_sessions` 控制：`max_sessions_per_poll` 只限制**每轮新开**几个，
   没有总量上限的话多轮会把 agent 堆叠在同一台机器上。`./status.sh` 会显示当前在跑的数量。

**进行中提示**：review 触发时会在 PR 上发一条"正在 review"评论，说明 reviewer、所用
provider/model 与 reasoning effort、以及正在审查的目标 HEAD commit；review 落地后该评论被
删除（agent 完成后自行删除 + poller 兜底清理），让团队随时知道目前谁在审、审的是哪个 commit。

### session_env：为什么必须配代理（否则 403）

`poll.sh` 手动跑时会继承你 shell 的环境变量，但 **systemd 启动时不会**——user service 的环境
非常干净。本机的模型 API 只能经由本地代理访问，直连会被拒：

```
{"is_error":true,"api_error_status":403,"result":"Failed to authenticate. API Error: 403 Request not allowed"}
```

现象是 session 启动一两秒后就退出、日志里只有上面这一行 JSON。所以把代理与 CA 证书路径写进
`session_env`，poll.sh 会在启动 agent 前把它们 export 到 session 进程里（两种 harness 都生效）：

```bash
./status.sh | grep '^Session env'      # 确认已加载
tr '\0' '\n' < /proc/<session-pid>/environ | grep -i proxy   # 确认真的进了进程
```

放在 `config.json`（已被 gitignore）而不是 systemd unit 里，是为了让仓库里的 unit 文件保持
与机器无关；同时手动跑和 timer 跑走的是同一份配置，不会出现"手动能跑、定时不能跑"的偏差。

## 调度（systemd 用户级 timer）

轮询由 systemd 用户级 timer 驱动：timer 每分钟唤醒 `pr-review-bot.service`（oneshot），
脚本按 `config.json` 的 `poll_interval_minutes` 节流，所以改频率只改配置文件即可。

> timer 用 `OnCalendar=*:0/1`（每个整分钟）而不是 `OnUnitActiveSec=1min`：后者从上一次运行
> **结束**开始计时，poll 本身耗时约 10s 就会把唤醒拖到约 2 分钟一次，脚本的 5 分钟节流实际
> 变成 6 分钟。改了 `systemd/` 下的 unit 之后需要重新安装才生效：
> `cp systemd/pr-review-bot.{service,timer} ~/.config/systemd/user/ && systemctl --user daemon-reload`

**unit 文件定义在哪里？** 不在本仓库里，而是安装在 systemd 的用户目录：

```
~/.config/systemd/user/pr-review-bot.service   # 实际工作单元（ExecStart=poll.sh）
~/.config/systemd/user/pr-review-bot.timer     # 每分钟触发的 timer
```

`enable` 时 systemd 会在 `~/.config/systemd/user/timers.target.wants/` 下创建一个指向
timer 的符号链接来实现开机自启。

本仓库的 `systemd/` 目录保存了这两个 unit 文件的副本（随代码一起版本化）。检查或安装：

```bash
# 查看定义与状态
systemctl --user cat pr-review-bot.timer
systemctl --user list-timers pr-review-bot.timer

# 从仓库重新安装（覆盖到 systemd 用户目录后重载）
cp systemd/pr-review-bot.service systemd/pr-review-bot.timer ~/.config/systemd/user/
systemctl --user daemon-reload

# 开启（激活 + 开机自启）/ 暂停 / 彻底停用
systemctl --user enable --now pr-review-bot.timer
systemctl --user stop pr-review-bot.timer
systemctl --user disable --now pr-review-bot.timer

# 立即跑一轮
systemctl --user start pr-review-bot.service   # 或 ./run-now.sh
```

### 路径可移植（跨机器 / 用户名不同）

- 脚本完全自定位（`BOT_DIR`），仓库可以放在任何目录。
- systemd unit 里**不能用 `~`**（systemd 不展开它），所以 service 用用户级 specifier
  `%h` 表示主目录：`ExecStart=%h/Workspace/pr-review-bot/poll.sh`。
  若你的仓库不在 `~/Workspace/pr-review-bot`，把两份 unit 拷贝安装前改一下
  `%h/Workspace/...` 那段为实际路径即可（脚本内部不需要改）。
- 工具路径（`gh`、`node`、DSH 的 `bin.js`）优先读环境变量 `GH` / `NODE` / `DSH_BIN`，
  未提供时自动探测常见位置（`command -v`，其次 `~/.nix-profile/bin` 与 `~/.local/share/dsh`）。

## 故障排查

- **定时任务没结果，但手动跑正常** → 两个已修的坑，若你从旧版本升级请一并检查：
  (1) service 必须带 `KillMode=process`，否则 `Type=oneshot` 的 unit 在 `poll.sh` 退出时会
  连带杀掉刚启动的 review session（`nohup`/`setsid` 都逃不出 cgroup），表现为 session 日志
  0 字节；(2) 见上文 `session_env`（403）。
- 机器重启/崩溃：进行中的 review session 会随进程终止，但下一次 poll 会自动为**仍被请求**的
  PR 重新开启 review（不做断点续传，从头重审）；`poll.log` 会打印 `SESSION-RECOVERY` 横幅，
  并逐条说明原因：`process vanished`（重启/崩溃/被 kill，日志为空）、`agent failed`（agent
  自己报错，附日志文件名）、`ended without posting a review`。已正常完成的 review 会顺带
  清理，不会误报。
- 私有仓库 clone/fetch 失败 → 确认 `gh auth status` 有 token；或在配置 `gh.token_env`
  指向一个含 GitHub token 的环境变量（例如在 systemd unit 或 shell 中 export）。
- 模型不对 → `dsh` 检查 `state/model-patch-<repo>.yml`（由合并后的 effective 配置生成）；
  `claude` 直接看 `poll.log` 里 launching 那行的 `harness=` / `model=`，或 session 日志 JSON 的 `modelUsage`。
- 机器上找不到 gh/node/DSH/claude → 显式设置 `GH`、`NODE`、`DSH_BIN`、`CLAUDE_BIN` 环境变量后重跑。
- `harness` 写错（既不是 `dsh` 也不是 `claude`）→ 该 PR 会在**发出任何 PR 评论之前**被跳过，
  `poll.log` 打印 `FATAL: unknown harness`。
- session 失败 → 查看对应 `logs/session-pr-*.log` 尾部报错。