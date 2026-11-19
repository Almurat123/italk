import { readFileSync, mkdirSync, writeFileSync } from 'node:fs';
import { resolve } from 'node:path';

// CONTEXT MEMORY
// Updated: 2026-11-01
// Status: inferred
// Why: The phone renderer and computer agent must use the same generated-interface vocabulary.
// Debug Goal: Generate the bundled remote skill from the iPhone's canonical instructions.
// Search Tags: remote generative ui shared skill sync schema
// Invariants:
// - The remote copy is derived from the same instructions as the iPhone skill.
// - Remote actions return to the originating computer as approval-controlled follow-up tasks.
// Failure Modes:
// - A manually maintained copy can drift and produce unsupported components.
const root = resolve(import.meta.dirname, '..');
const swift = readFileSync(resolve(root, 'apps/iOS/GenerativeUISkill.swift'), 'utf8');
const match = swift.match(/static let instructions = #"""\n([\s\S]*?)\n\s*"""#/);
if (!match) throw new Error('Cannot find canonical generative UI instructions');
const header = `---
name: interactive-ui
description: Compose native visual explanations, charts, comparisons and local-only controls in iTalk answers.
version: 1.0.0
tags: [interface, visualization]
---

# iTalk interface on a remote task

The following component vocabulary is shared with iTalk on the phone. A send or tool action creates a visible follow-up task on this same computer. It does not execute the requested tool directly; the normal permissions and approvals still apply.

`;
const folder = resolve(root, 'remote/agent/skills/interactive-ui');
mkdirSync(folder, { recursive: true });
writeFileSync(resolve(folder, 'SKILL.md'), header + match[1].replace(/^    /gm, '') + '\n');
console.log('Updated remote interactive-ui skill from the iPhone specification.');
