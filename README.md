# PR Review Bot（DSH headless）

自动监听 GitHub 仓库中请求指定 reviewer 审查的 PR，用 DSH headless session 以你配置的
模型（provider + model + reasoningEffort）完成代码审查，并通过 GitHub API 把 review
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
  "mention_window_hours": 24,           // 只关注最近 N 小时内的 @mention 评论
  "model": {                            // 全局默认模型
    "provider": "opencode-go",
    "model": "deepseek-v4-flash",
    "reasoningEffort": "max"
  },
  "gh": {
    "token_env": "",                    // 可选：读哪个环境变量作为 GitHub token（留空=用 gh keyring）
    "base_url": "https://github.com"    // GitHub Enterprise 可改
  },
  "custom_prompt": "<全局默认审查指令>",
  "git_dir": "git",                     // mirror 存放目录（相对本目录或绝对路径）
  "worktree_base": "worktrees",         // worktree 根目录
  "repos": [
    { "repo": "org/repo-a", "reviewer": "reviewer-a" },          // 只覆盖 reviewer
    { "repo": "org/repo-b",                                        // 其余全部用全局默认
      "model": { "provider": "opencode-go", "model": "deepseek-v4-flash", "reasoningEffort": "max" },
      "custom_prompt": "Focus on security..." }                    // 仓库级模型与审查指令
  ]
}
```

> 可覆盖的字段：`reviewer`、`model.provider`、`model.model`、`model.reasoningEffort`、`custom_prompt`。

> `config.json` 位于本目录，而本目录不在任何 git 仓库内，因此不会被提交；目录内 `.gitignore`
> 也把 `config.json`、`state/`、`logs/`、`git/`、`worktrees/` 都忽略了，即使整个目录将来被
> 纳入版本控制也安全。

## 常用操作

查看当前状态（正在 review 哪些 PR、进行中/已完成/失败、等待队列）：

```bash
./status.sh          # 或 ./run-now.sh status
```

立即轮询一次（绕过间隔）：

```bash
./run-now.sh
```

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

注意：headless review 会话是**独立进程**，不会出现在 DSH Web GUI 的会话列表里
（GUI 只显示在 `dsh web` 里创建的会话）。review 的最终结果是贴在 GitHub PR 上的
review；过程日志在 `logs/` 下；会话期间日志文件通常是空的，结束后一次性写入。

## 工作原理

1. **发现**：每个仓库用 GitHub Search GraphQL 查 `review-requested:<该仓库的 reviewer>` 的
   open PR；另外扫描最近 N 小时内的 issue/PR 评论中 `@<reviewer>` 的提及。
2. **去重与 re-request**：`state.json` 记录已处理/已 review 的 PR（含当时的 head_sha）与评论 id，
   避免重复触发。如果某个 PR 之后又被 re-request review，仅当**内容有变化**时才重新审查：
   PR head 出现了新 commit，或之前的 review 已被 dismiss；否则跳过。
   正在运行中的 review session 也不会被重复触发。
3. **审查**：每个新 PR 启动一个 DSH headless session，prompt 指引 agent：
   在对应仓库的 git worktree 里拉取该 PR 的 head，`git diff` 对比 base 分支，逐文件阅读，
   按 custom prompt 审计，最后用 `gh api .../pulls/N/reviews` 一次性提交 review
   （inline comments 优先）。结果判定：**没有 blocking 问题时 approve 是正常终点**（可附带
   inline 建议）；有阻塞问题才 REQUEST_CHANGES；拿不准/草稿阶段用 COMMENT。
4. **清理**：session 结束后自动移除 worktree，多个 PR 并行互不冲突。

## 调度（systemd 用户级 timer）

轮询由 systemd 用户级 timer 驱动：timer 每分钟唤醒 `pr-review-bot.service`（oneshot），
脚本按 `config.json` 的 `poll_interval_minutes` 节流，所以改频率只改配置文件即可。

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

- 私有仓库 clone/fetch 失败 → 确认 `gh auth status` 有 token；或在配置 `gh.token_env`
  指向一个含 GitHub token 的环境变量（例如在 systemd unit 或 shell 中 export）。
- 模型不对 → 检查 `state/model-patch-<repo>.yml`，它由合并后的 effective 配置生成。
- 机器上找不到 gh/node/DSH → 显式设置 `GH`、`NODE`、`DSH_BIN` 环境变量后重跑。
- session 失败 → 查看对应 `logs/session-pr-*.log` 尾部报错。