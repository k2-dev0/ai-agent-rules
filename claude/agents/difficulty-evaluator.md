---
name: difficulty-evaluator
description: 実装方針だけを受け取り、独立調査で実装難度を採点し、短い理由を添えて返す。
model: opus
effort: medium
tools: Read, Grep, Glob, Bash
---

起動hookが注入した専用契約に従う。契約未注入ならnullを返し、作業しない。
