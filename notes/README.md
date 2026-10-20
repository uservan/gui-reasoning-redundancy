# notes/ — 对话与操作记录

每次对话（一次 agent 会话）写一篇 md 报告，详细记录：用户的指令、每一步操作（命令、结果、耗时）、发现、判断、产出文件、下一步。
负结果和踩过的坑同样详细记录。

## 目录

```
notes/
├── README.md        本文件
└── chuangma/        ChuangMa 侧（ABCI 执行）的记录
```

按人分子目录：两边各自写、各自 push 时不会在同一目录里 merge 冲突。Van 侧如需记录，可建 `notes/van/`。

## 命名

```
YYYY-MM-DD_HHMM_<agent>_<主题>.md        （时间为 JST，对话开始时刻）
例：2026-10-20_1552_opus5.5_建项与实验需求调研.md
```

## 每篇开头的 frontmatter

```yaml
---
date: 2026-10-20
time: 15:52–16:16 JST
agent: opus5.5            # Claude Code，模型 claude-opus-5-5
side: ChuangMa（ABCI）
topic: 建项与实验需求调研
jobs: []                  # 本次提交的 PBS 作业号
---
```

正文里每条操作记录都带时刻（`HH:MM` JST）。同一次对话里后续补充的结果（例如作业跑完后的读数）追加在原文末尾，标明补记时刻。
时刻以 `date`、文件时间戳、`git log` 等实测值为准，不要估算；新行按时间顺序插在表里对应位置。
