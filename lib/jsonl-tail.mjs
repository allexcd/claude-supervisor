#!/usr/bin/env node
// lib/jsonl-tail.mjs — Extract current status from a Claude Code session JSONL file
//
// Usage: node lib/jsonl-tail.mjs <jsonl-file-path>
// Output: single JSON line with status info
//
// Status values:
//   "tool"      — agent is calling a tool (tool name in .tool field)
//   "thinking"  — agent is in thinking/reasoning mode
//   "writing"   — agent is writing a text response
//   "waiting"   — user turn just ended; agent is processing
//   "idle"      — no recent assistant activity
//   "unknown"   — could not read or parse the file

import { readFileSync } from 'node:fs';

const [,, file] = process.argv;

if (!file) {
  process.stdout.write(JSON.stringify({ status: 'unknown', tool: null, timestamp: null, sessionId: null }) + '\n');
  process.exit(0);
}

let lines;
try {
  const raw = readFileSync(file, 'utf8');
  lines = raw.split('\n').filter(Boolean);
  // Only look at the last 100 events for performance
  if (lines.length > 100) lines = lines.slice(-100);
} catch {
  process.stdout.write(JSON.stringify({ status: 'unknown', tool: null, timestamp: null, sessionId: null }) + '\n');
  process.exit(0);
}

let lastTool = null;
let lastTimestamp = null;
let lastStatus = 'idle';
let sessionId = null;

for (const line of lines) {
  try {
    const obj = JSON.parse(line);

    // Track timestamps from any event that has one
    if (obj.timestamp) lastTimestamp = obj.timestamp;

    // Capture session ID
    if (obj.sessionId && !sessionId) sessionId = obj.sessionId;
    if (obj.type === 'permission-mode' && obj.sessionId) sessionId = obj.sessionId;

    if (obj.type === 'assistant') {
      const content = Array.isArray(obj.message?.content) ? obj.message.content : [];
      for (const c of content) {
        if (c.type === 'tool_use') {
          lastTool = c.name ?? null;
          lastStatus = 'tool';
        } else if (c.type === 'thinking') {
          lastStatus = 'thinking';
          lastTool = null;
        } else if (c.type === 'text' && typeof c.text === 'string' && c.text.trim()) {
          lastStatus = 'writing';
          lastTool = null;
        }
      }
    } else if (obj.type === 'user') {
      // User turn just ended — Claude is about to respond
      lastStatus = 'waiting';
      lastTool = null;
    } else if (obj.type === 'last-prompt') {
      // Session is idle / ended
      lastStatus = 'idle';
      lastTool = null;
    }
  } catch {
    // Skip malformed JSON lines
  }
}

process.stdout.write(JSON.stringify({ status: lastStatus, tool: lastTool, timestamp: lastTimestamp, sessionId }) + '\n');
