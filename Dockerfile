# ============================================================
# LOCAL AI GATEWAY — Production Dockerfile
# Deploy on Render.com or any Docker host
# Single-file, no external dependencies
# ============================================================
FROM ubuntu:22.04

# Prevent interactive prompts during build
ENV DEBIAN_FRONTEND=noninteractive
ENV NODE_ENV=production
ENV PORT=3000
ENV DB_PATH=/app/data/gateway.db
ENV MODEL_DIR=/app/models
ENV LLAMA_DIR=/app/llama.cpp

# ─────────────────────────────────────────────
# 1. SYSTEM DEPENDENCIES
# ─────────────────────────────────────────────
RUN apt-get update && apt-get install -y \
    curl \
    git \
    build-essential \
    cmake \
    python3 \
    python3-pip \
    wget \
    ca-certificates \
    sqlite3 \
    && curl -fsSL https://deb.nodesource.com/setup_20.x | bash - \
    && apt-get install -y nodejs \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

# ─────────────────────────────────────────────
# 2. BUILD llama.cpp
# ─────────────────────────────────────────────
WORKDIR /app

RUN git clone --depth=1 https://github.com/ggerganov/llama.cpp.git ${LLAMA_DIR} \
    && cd ${LLAMA_DIR} \
    && cmake -B build -DLLAMA_BUILD_SERVER=OFF -DBUILD_SHARED_LIBS=OFF \
    && cmake --build build --config Release -j$(nproc) \
    && cp build/bin/llama-cli /usr/local/bin/llama-cli || \
       cp build/bin/main /usr/local/bin/llama-cli 2>/dev/null || \
       find build -name "llama-cli" -o -name "main" | head -1 | xargs -I{} cp {} /usr/local/bin/llama-cli

# ─────────────────────────────────────────────
# 3. NODE PROJECT SCAFFOLD
# ─────────────────────────────────────────────
WORKDIR /app
RUN mkdir -p data models src logs

# ── package.json ──────────────────────────────
RUN cat <<'EOF' > /app/package.json
{
  "name": "local-ai-gateway",
  "version": "2.0.0",
  "description": "Private, offline AI API Gateway powered by llama.cpp",
  "main": "src/server.js",
  "scripts": {
    "start": "node src/server.js",
    "dev": "node src/server.js"
  },
  "dependencies": {
    "express": "^4.18.2",
    "better-sqlite3": "^9.4.3",
    "uuid": "^9.0.0",
    "morgan": "^1.10.0",
    "helmet": "^7.1.0",
    "express-rate-limit": "^7.1.5",
    "dotenv": "^16.3.1"
  }
}
EOF

# ─────────────────────────────────────────────
# 4. roles.js — Role hierarchy & permissions
# ─────────────────────────────────────────────
RUN cat <<'EOF' > /app/src/roles.js
/**
 * Role Hierarchy & Permission Matrix
 * Higher index = higher privilege
 */

const ROLES = {
  VISITOR:          { level: 0, tokenLimit: 0,    canAccessAI: false, canManageKeys: false, canViewAnalytics: false, canManageAdmins: false },
  USER:             { level: 1, tokenLimit: 500,   canAccessAI: true,  canManageKeys: false, canViewAnalytics: false, canManageAdmins: false },
  PRO_USER:         { level: 2, tokenLimit: 1000,  canAccessAI: true,  canManageKeys: false, canViewAnalytics: false, canManageAdmins: false },
  VIP_USER:         { level: 3, tokenLimit: 2000,  canAccessAI: true,  canManageKeys: false, canViewAnalytics: false, canManageAdmins: false },
  WORKER:           { level: 4, tokenLimit: 800,   canAccessAI: true,  canManageKeys: false, canViewAnalytics: false, canManageAdmins: false },
  SUPERVISOR:       { level: 5, tokenLimit: 1500,  canAccessAI: true,  canManageKeys: false, canViewAnalytics: true,  canManageAdmins: false },
  ADMIN:            { level: 6, tokenLimit: 3000,  canAccessAI: true,  canManageKeys: true,  canViewAnalytics: true,  canManageAdmins: false },
  SUPER_ADMIN:      { level: 7, tokenLimit: 5000,  canAccessAI: true,  canManageKeys: true,  canViewAnalytics: true,  canManageAdmins: true  },
  PROGRAMMER_TEAM:  { level: 8, tokenLimit: 99999, canAccessAI: true,  canManageKeys: true,  canViewAnalytics: true,  canManageAdmins: true  },
};

const ROLE_NAMES = Object.keys(ROLES);

function getRole(roleName) {
  return ROLES[roleName] || null;
}

function hasPermission(roleName, permission) {
  const role = getRole(roleName);
  if (!role) return false;
  return role[permission] === true;
}

function getTokenLimit(roleName) {
  const role = getRole(roleName);
  return role ? role.tokenLimit : 0;
}

function isValidRole(roleName) {
  return ROLE_NAMES.includes(roleName);
}

function canRoleManage(managerRole, targetRole) {
  const mgr = getRole(managerRole);
  const tgt = getRole(targetRole);
  if (!mgr || !tgt) return false;
  return mgr.level > tgt.level;
}

module.exports = { ROLES, ROLE_NAMES, getRole, hasPermission, getTokenLimit, isValidRole, canRoleManage };
EOF

# ─────────────────────────────────────────────
# 5. database.js — SQLite layer
# ─────────────────────────────────────────────
RUN cat <<'EOF' > /app/src/database.js
const Database = require('better-sqlite3');
const path = require('path');
const { v4: uuidv4 } = require('uuid');
const { ROLE_NAMES } = require('./roles');

const DB_PATH = process.env.DB_PATH || '/app/data/gateway.db';

let db;

function getDB() {
  if (!db) {
    db = new Database(DB_PATH);
    db.pragma('journal_mode = WAL');
    db.pragma('foreign_keys = ON');
    initSchema();
  }
  return db;
}

function initSchema() {
  const database = getDB();

  // API Keys table
  database.exec(`
    CREATE TABLE IF NOT EXISTS api_keys (
      id          TEXT PRIMARY KEY,
      api_key     TEXT UNIQUE NOT NULL,
      name        TEXT NOT NULL DEFAULT 'Unnamed Key',
      role        TEXT NOT NULL DEFAULT 'USER',
      quota       INTEGER NOT NULL DEFAULT 1000,
      used        INTEGER NOT NULL DEFAULT 0,
      enabled     INTEGER NOT NULL DEFAULT 1,
      created_at  TEXT NOT NULL DEFAULT (datetime('now')),
      updated_at  TEXT NOT NULL DEFAULT (datetime('now'))
    );
  `);

  // Request logs table
  database.exec(`
    CREATE TABLE IF NOT EXISTS request_logs (
      id          TEXT PRIMARY KEY,
      api_key_id  TEXT,
      endpoint    TEXT,
      tokens_used INTEGER DEFAULT 0,
      duration_ms INTEGER DEFAULT 0,
      status      INTEGER DEFAULT 200,
      created_at  TEXT NOT NULL DEFAULT (datetime('now')),
      FOREIGN KEY(api_key_id) REFERENCES api_keys(id)
    );
  `);

  // Seed a default PROGRAMMER_TEAM key if no keys exist
  const count = database.prepare('SELECT COUNT(*) as c FROM api_keys').get();
  if (count.c === 0) {
    const masterKey = 'gateway-master-' + uuidv4().replace(/-/g, '').substring(0, 16);
    database.prepare(`
      INSERT INTO api_keys (id, api_key, name, role, quota, enabled)
      VALUES (?, ?, ?, ?, ?, 1)
    `).run(uuidv4(), masterKey, 'Master Key', 'PROGRAMMER_TEAM', 999999);
    console.log('\n╔══════════════════════════════════════════════╗');
    console.log('║        🔑  MASTER API KEY GENERATED          ║');
    console.log('╠══════════════════════════════════════════════╣');
    console.log(`║  ${masterKey}  ║`);
    console.log('╚══════════════════════════════════════════════╝\n');
    console.log('⚠  Save this key — it will not be shown again.\n');
  }
}

// ── Key CRUD ─────────────────────────────────

function createKey({ name, role, quota }) {
  const database = getDB();
  const id = uuidv4();
  const api_key = 'gw-' + uuidv4().replace(/-/g, '');
  database.prepare(`
    INSERT INTO api_keys (id, api_key, name, role, quota)
    VALUES (?, ?, ?, ?, ?)
  `).run(id, api_key, name || 'Unnamed Key', role || 'USER', quota || 1000);
  return database.prepare('SELECT * FROM api_keys WHERE id = ?').get(id);
}

function listKeys() {
  return getDB().prepare('SELECT * FROM api_keys ORDER BY created_at DESC').all();
}

function getKeyByValue(api_key) {
  return getDB().prepare('SELECT * FROM api_keys WHERE api_key = ? AND enabled = 1').get(api_key);
}

function getKeyById(id) {
  return getDB().prepare('SELECT * FROM api_keys WHERE id = ?').get(id);
}

function deleteKey(id) {
  const result = getDB().prepare('DELETE FROM api_keys WHERE id = ?').run(id);
  return result.changes > 0;
}

function updateKeyUsage(id, tokensUsed) {
  getDB().prepare(`
    UPDATE api_keys SET used = used + ?, updated_at = datetime('now') WHERE id = ?
  `).run(tokensUsed, id);
}

function logRequest({ api_key_id, endpoint, tokens_used, duration_ms, status }) {
  getDB().prepare(`
    INSERT INTO request_logs (id, api_key_id, endpoint, tokens_used, duration_ms, status)
    VALUES (?, ?, ?, ?, ?, ?)
  `).run(uuidv4(), api_key_id, endpoint, tokens_used || 0, duration_ms || 0, status || 200);
}

function getAnalytics() {
  const db = getDB();
  return {
    totalRequests: db.prepare('SELECT COUNT(*) as c FROM request_logs').get().c,
    totalKeys: db.prepare('SELECT COUNT(*) as c FROM api_keys').get().c,
    activeKeys: db.prepare('SELECT COUNT(*) as c FROM api_keys WHERE enabled = 1').get().c,
    requestsByEndpoint: db.prepare(`
      SELECT endpoint, COUNT(*) as count, AVG(duration_ms) as avg_ms
      FROM request_logs GROUP BY endpoint ORDER BY count DESC
    `).all(),
    recentRequests: db.prepare(`
      SELECT r.*, k.name as key_name, k.role
      FROM request_logs r
      LEFT JOIN api_keys k ON r.api_key_id = k.id
      ORDER BY r.created_at DESC LIMIT 20
    `).all(),
  };
}

module.exports = { getDB, initSchema, createKey, listKeys, getKeyByValue, getKeyById, deleteKey, updateKeyUsage, logRequest, getAnalytics };
EOF

# ─────────────────────────────────────────────
# 6. ai.js — llama.cpp inference engine
# ─────────────────────────────────────────────
RUN cat <<'EOF' > /app/src/ai.js
const { execFile } = require('child_process');
const path = require('path');
const fs = require('fs');

const MODEL_DIR = process.env.MODEL_DIR || '/app/models';
const LLAMA_BIN = process.env.LLAMA_BIN || 'llama-cli';

// System prompts per endpoint type
const SYSTEM_PROMPTS = {
  chat: 'You are a helpful, concise AI assistant. Respond clearly and directly.',
  code: 'You are an expert programming assistant. Provide clean, well-commented code with brief explanations. Focus on correctness and best practices.',
  summarize: 'You are a summarization expert. Produce clear, concise summaries that capture the key points. Use bullet points where appropriate.',
  translate: 'You are a professional translator. Translate accurately while preserving tone, nuance, and meaning. If no target language is specified, translate to English.',
};

function findModel() {
  if (!fs.existsSync(MODEL_DIR)) return null;
  const files = fs.readdirSync(MODEL_DIR).filter(f => f.endsWith('.gguf'));
  if (files.length === 0) return null;
  // Prefer smaller/faster models
  const preferred = files.find(f => f.includes('tinyllama') || f.includes('phi') || f.includes('tiny'));
  return path.join(MODEL_DIR, preferred || files[0]);
}

function buildPrompt(type, userMessage, options = {}) {
  const systemPrompt = SYSTEM_PROMPTS[type] || SYSTEM_PROMPTS.chat;
  const { targetLanguage, codeLanguage } = options;

  let contextNote = '';
  if (type === 'translate' && targetLanguage) contextNote = `\nTarget language: ${targetLanguage}`;
  if (type === 'code' && codeLanguage) contextNote = `\nPreferred language: ${codeLanguage}`;

  // TinyLlama / Phi-3 style prompt format
  return `<|system|>\n${systemPrompt}${contextNote}<|end|>\n<|user|>\n${userMessage}<|end|>\n<|assistant|>`;
}

function runInference(prompt, tokenLimit = 500) {
  return new Promise((resolve, reject) => {
    const modelPath = findModel();
    if (!modelPath) {
      return reject(new Error('No model found. Please wait for model download to complete and retry.'));
    }

    const args = [
      '-m', modelPath,
      '-p', prompt,
      '-n', String(Math.min(tokenLimit, 4096)),
      '--temp', '0.7',
      '--top-p', '0.9',
      '--repeat-penalty', '1.1',
      '-c', '2048',
      '--log-disable',
      '-e',          // escape newlines
    ];

    const startTime = Date.now();
    let stdout = '';
    let stderr = '';

    const child = execFile(LLAMA_BIN, args, {
      timeout: 120000, // 2 min timeout
      maxBuffer: 10 * 1024 * 1024,
    }, (error, out, err) => {
      const duration = Date.now() - startTime;
      if (error && !stdout) {
        return reject(new Error(`Inference failed: ${error.message}`));
      }
      // Strip the echoed prompt from output
      let response = out || stdout;
      const assistantMarker = '<|assistant|>';
      const markerIdx = response.lastIndexOf(assistantMarker);
      if (markerIdx !== -1) {
        response = response.substring(markerIdx + assistantMarker.length);
      }
      // Remove end-of-sequence tokens
      response = response
        .replace(/<\|end\|>/g, '')
        .replace(/<\|endoftext\|>/g, '')
        .replace(/\[end of text\]/gi, '')
        .trim();

      // Rough token estimate (words / 0.75)
      const estimatedTokens = Math.ceil(response.split(/\s+/).length / 0.75);

      resolve({ response, duration_ms: duration, tokens_used: estimatedTokens });
    });
  });
}

async function chat(message, tokenLimit) {
  const prompt = buildPrompt('chat', message);
  return runInference(prompt, tokenLimit);
}

async function code(message, options, tokenLimit) {
  const prompt = buildPrompt('code', message, options);
  return runInference(prompt, tokenLimit);
}

async function summarize(text, tokenLimit) {
  const prompt = buildPrompt('summarize', `Please summarize the following:\n\n${text}`);
  return runInference(prompt, tokenLimit);
}

async function translate(text, options, tokenLimit) {
  const prompt = buildPrompt('translate', text, options);
  return runInference(prompt, tokenLimit);
}

function modelStatus() {
  const modelPath = findModel();
  if (!modelPath) return { ready: false, model: null };
  const stats = fs.statSync(modelPath);
  return {
    ready: true,
    model: path.basename(modelPath),
    size_mb: Math.round(stats.size / 1024 / 1024),
    path: modelPath,
  };
}

module.exports = { chat, code, summarize, translate, modelStatus };
EOF

# ─────────────────────────────────────────────
# 7. middleware.js — Auth, rate limiting, roles
# ─────────────────────────────────────────────
RUN cat <<'EOF' > /app/src/middleware.js
const { getKeyByValue } = require('./database');
const { hasPermission, getTokenLimit } = require('./roles');

/**
 * API Key authentication middleware
 * Reads x-api-key header, validates against DB
 */
function authenticate(req, res, next) {
  const apiKey = req.headers['x-api-key'];

  if (!apiKey) {
    return res.status(401).json({
      error: 'Unauthorized',
      message: 'Missing x-api-key header',
      docs: 'Include your API key: x-api-key: YOUR_KEY',
    });
  }

  const keyRecord = getKeyByValue(apiKey);

  if (!keyRecord) {
    return res.status(401).json({
      error: 'Unauthorized',
      message: 'Invalid or disabled API key',
    });
  }

  // Quota check
  if (keyRecord.quota > 0 && keyRecord.used >= keyRecord.quota) {
    return res.status(429).json({
      error: 'Quota Exceeded',
      message: `You have used all ${keyRecord.quota} allocated tokens for this key`,
      used: keyRecord.used,
      quota: keyRecord.quota,
    });
  }

  // Attach to request
  req.apiKey = keyRecord;
  req.tokenLimit = getTokenLimit(keyRecord.role);
  next();
}

/**
 * Permission check middleware factory
 */
function requirePermission(permission) {
  return (req, res, next) => {
    if (!req.apiKey) {
      return res.status(401).json({ error: 'Unauthorized' });
    }
    if (!hasPermission(req.apiKey.role, permission)) {
      return res.status(403).json({
        error: 'Forbidden',
        message: `Your role (${req.apiKey.role}) does not have permission: ${permission}`,
        your_role: req.apiKey.role,
        required_permission: permission,
      });
    }
    next();
  };
}

/**
 * AI access guard — checks canAccessAI permission
 */
function requireAIAccess(req, res, next) {
  if (!req.apiKey) return res.status(401).json({ error: 'Unauthorized' });
  if (!hasPermission(req.apiKey.role, 'canAccessAI')) {
    return res.status(403).json({
      error: 'Forbidden',
      message: 'Your role does not have AI access',
      your_role: req.apiKey.role,
    });
  }
  if (req.tokenLimit <= 0) {
    return res.status(403).json({
      error: 'Forbidden',
      message: 'No token limit configured for your role',
    });
  }
  next();
}

module.exports = { authenticate, requirePermission, requireAIAccess };
EOF

# ─────────────────────────────────────────────
# 8. server.js — Main Express application
# ─────────────────────────────────────────────
RUN cat <<'EOF' > /app/src/server.js
require('dotenv').config();
const express = require('express');
const helmet = require('helmet');
const morgan = require('morgan');
const rateLimit = require('express-rate-limit');
const { v4: uuidv4 } = require('uuid');

const { initSchema, createKey, listKeys, getKeyById, deleteKey, updateKeyUsage, logRequest, getAnalytics } = require('./database');
const { authenticate, requirePermission, requireAIAccess } = require('./middleware');
const { chat, code, summarize, translate, modelStatus } = require('./ai');
const { ROLE_NAMES, isValidRole, canRoleManage } = require('./roles');

const app = express();
const PORT = process.env.PORT || 3000;
const START_TIME = Date.now();

// ── Security & Parsing ────────────────────────
app.use(helmet());
app.use(express.json({ limit: '2mb' }));
app.use(morgan('combined'));

// Global rate limiter (per IP)
app.use(rateLimit({
  windowMs: 60 * 1000,
  max: 120,
  message: { error: 'Too many requests', message: 'Rate limit: 120 req/min per IP' },
}));

// ── Init DB ───────────────────────────────────
initSchema();

// ─────────────────────────────────────────────
// HEALTH CHECK
// ─────────────────────────────────────────────
app.get('/', (req, res) => {
  const model = modelStatus();
  res.json({
    service: 'Local AI Gateway',
    version: '2.0.0',
    status: 'operational',
    uptime_seconds: Math.floor((Date.now() - START_TIME) / 1000),
    model: model,
    timestamp: new Date().toISOString(),
    endpoints: {
      health: 'GET /',
      chat: 'POST /ai/chat',
      code: 'POST /ai/code',
      summarize: 'POST /ai/summarize',
      translate: 'POST /ai/translate',
      createKey: 'POST /admin/create-key',
      listKeys: 'GET /admin/keys',
      deleteKey: 'DELETE /admin/key/:id',
      analytics: 'GET /admin/analytics',
    },
  });
});

app.get('/health', (req, res) => {
  res.json({ status: 'ok', model: modelStatus() });
});

// ─────────────────────────────────────────────
// AI ENDPOINTS
// ─────────────────────────────────────────────

// Helper: wrap AI calls with logging & error handling
async function aiEndpoint(req, res, aiFunction, endpointName) {
  const started = Date.now();
  try {
    const result = await aiFunction();
    const duration = Date.now() - started;

    // Update usage stats
    updateKeyUsage(req.apiKey.id, result.tokens_used || 0);
    logRequest({
      api_key_id: req.apiKey.id,
      endpoint: endpointName,
      tokens_used: result.tokens_used,
      duration_ms: duration,
      status: 200,
    });

    res.json({
      success: true,
      response: result.response,
      meta: {
        tokens_used: result.tokens_used,
        duration_ms: result.duration_ms,
        role: req.apiKey.role,
        token_limit: req.tokenLimit,
      },
    });
  } catch (err) {
    const duration = Date.now() - started;
    logRequest({ api_key_id: req.apiKey.id, endpoint: endpointName, duration_ms: duration, status: 500 });
    console.error(`[${endpointName}] Error:`, err.message);
    res.status(500).json({ error: 'AI inference failed', message: err.message });
  }
}

// POST /ai/chat
app.post('/ai/chat', authenticate, requireAIAccess, async (req, res) => {
  const { message } = req.body;
  if (!message || typeof message !== 'string' || !message.trim()) {
    return res.status(400).json({ error: 'Bad Request', message: '"message" field is required' });
  }
  await aiEndpoint(req, res, () => chat(message.trim(), req.tokenLimit), '/ai/chat');
});

// POST /ai/code
app.post('/ai/code', authenticate, requireAIAccess, async (req, res) => {
  const { message, language } = req.body;
  if (!message || typeof message !== 'string' || !message.trim()) {
    return res.status(400).json({ error: 'Bad Request', message: '"message" field is required' });
  }
  await aiEndpoint(req, res, () => code(message.trim(), { codeLanguage: language }, req.tokenLimit), '/ai/code');
});

// POST /ai/summarize
app.post('/ai/summarize', authenticate, requireAIAccess, async (req, res) => {
  const { text } = req.body;
  if (!text || typeof text !== 'string' || !text.trim()) {
    return res.status(400).json({ error: 'Bad Request', message: '"text" field is required' });
  }
  await aiEndpoint(req, res, () => summarize(text.trim(), req.tokenLimit), '/ai/summarize');
});

// POST /ai/translate
app.post('/ai/translate', authenticate, requireAIAccess, async (req, res) => {
  const { text, targetLanguage } = req.body;
  if (!text || typeof text !== 'string' || !text.trim()) {
    return res.status(400).json({ error: 'Bad Request', message: '"text" field is required' });
  }
  await aiEndpoint(req, res, () => translate(text.trim(), { targetLanguage }, req.tokenLimit), '/ai/translate');
});

// ─────────────────────────────────────────────
// ADMIN ENDPOINTS
// ─────────────────────────────────────────────

// POST /admin/create-key
app.post('/admin/create-key', authenticate, requirePermission('canManageKeys'), (req, res) => {
  const { name, role, quota } = req.body;

  if (role && !isValidRole(role)) {
    return res.status(400).json({
      error: 'Invalid role',
      valid_roles: ROLE_NAMES,
    });
  }

  // Prevent privilege escalation
  if (role && !canRoleManage(req.apiKey.role, role) && req.apiKey.role !== 'PROGRAMMER_TEAM') {
    return res.status(403).json({
      error: 'Forbidden',
      message: `You cannot create keys with role ${role} (your role: ${req.apiKey.role})`,
    });
  }

  const newKey = createKey({ name, role: role || 'USER', quota: quota || 1000 });
  res.status(201).json({
    success: true,
    message: 'API key created',
    key: newKey,
  });
});

// GET /admin/keys
app.get('/admin/keys', authenticate, requirePermission('canManageKeys'), (req, res) => {
  const keys = listKeys();
  // Mask key values for non-PROGRAMMER_TEAM roles
  const masked = keys.map(k => ({
    ...k,
    api_key: req.apiKey.role === 'PROGRAMMER_TEAM'
      ? k.api_key
      : k.api_key.substring(0, 8) + '...' + k.api_key.slice(-4),
  }));
  res.json({ success: true, count: masked.length, keys: masked });
});

// DELETE /admin/key/:id
app.delete('/admin/key/:id', authenticate, requirePermission('canManageKeys'), (req, res) => {
  const { id } = req.params;

  // Prevent self-deletion
  if (id === req.apiKey.id) {
    return res.status(400).json({ error: 'You cannot delete your own key' });
  }

  const target = getKeyById(id);
  if (!target) return res.status(404).json({ error: 'Key not found' });

  // Role check
  if (!canRoleManage(req.apiKey.role, target.role) && req.apiKey.role !== 'PROGRAMMER_TEAM') {
    return res.status(403).json({ error: 'Forbidden', message: 'Insufficient role to delete this key' });
  }

  const deleted = deleteKey(id);
  res.json({ success: deleted, message: deleted ? 'Key deleted' : 'Key not found' });
});

// GET /admin/analytics
app.get('/admin/analytics', authenticate, requirePermission('canViewAnalytics'), (req, res) => {
  res.json({ success: true, analytics: getAnalytics() });
});

// ─────────────────────────────────────────────
// 404 & Error handlers
// ─────────────────────────────────────────────
app.use((req, res) => {
  res.status(404).json({ error: 'Not Found', path: req.path });
});

app.use((err, req, res, next) => {
  console.error('Unhandled error:', err);
  res.status(500).json({ error: 'Internal Server Error' });
});

// ─────────────────────────────────────────────
// START
// ─────────────────────────────────────────────
app.listen(PORT, '0.0.0.0', () => {
  console.log(`\n🚀 Local AI Gateway running on port ${PORT}`);
  console.log(`📊 Health check: http://localhost:${PORT}/`);
  console.log(`🤖 Model status: ${JSON.stringify(modelStatus())}\n`);
});
EOF

# ─────────────────────────────────────────────
# 9. start.sh — Container entrypoint
# ─────────────────────────────────────────────
RUN cat <<'EOF' > /app/start.sh
#!/bin/bash
set -e

echo "╔══════════════════════════════════════════╗"
echo "║      🧠  Local AI Gateway  v2.0          ║"
echo "╚══════════════════════════════════════════╝"

MODEL_DIR="${MODEL_DIR:-/app/models}"
MODEL_FILE="${MODEL_DIR}/tinyllama-1.1b-chat-v1.0.Q4_K_M.gguf"
MODEL_URL="https://huggingface.co/TheBloke/TinyLlama-1.1B-Chat-v1.0-GGUF/resolve/main/tinyllama-1.1b-chat-v1.0.Q4_K_M.gguf"

mkdir -p "${MODEL_DIR}"
mkdir -p /app/data
mkdir -p /app/logs

# ── Download model if missing ─────────────────
if [ ! -f "${MODEL_FILE}" ]; then
  echo ""
  echo "📥 Downloading TinyLlama 1.1B (Q4_K_M, ~700MB)..."
  echo "   This happens only once on first startup."
  echo ""
  wget --progress=bar:force:noscroll \
       -O "${MODEL_FILE}.tmp" \
       "${MODEL_URL}" \
  && mv "${MODEL_FILE}.tmp" "${MODEL_FILE}" \
  && echo "✅ Model downloaded: ${MODEL_FILE}" \
  || {
    echo "⚠  Primary model download failed. Trying Phi-3 Mini..."
    PHI_FILE="${MODEL_DIR}/phi-3-mini-4k-instruct.Q4_K_M.gguf"
    PHI_URL="https://huggingface.co/microsoft/Phi-3-mini-4k-instruct-gguf/resolve/main/Phi-3-mini-4k-instruct-q4.gguf"
    wget --progress=bar:force:noscroll -O "${PHI_FILE}.tmp" "${PHI_URL}" \
    && mv "${PHI_FILE}.tmp" "${PHI_FILE}" \
    && echo "✅ Phi-3 Mini downloaded." \
    || echo "❌ Model download failed — AI endpoints will return errors until a model is present."
  }
else
  echo "✅ Model found: $(basename ${MODEL_FILE})"
fi

# ── Validate llama-cli ────────────────────────
if command -v llama-cli &> /dev/null; then
  echo "✅ llama-cli ready: $(llama-cli --version 2>&1 | head -1 || echo 'ok')"
else
  echo "❌ llama-cli not found in PATH"
  exit 1
fi

# ── Start Node server ─────────────────────────
echo ""
echo "🚀 Starting AI Gateway server..."
cd /app
exec node src/server.js
EOF

chmod +x /app/start.sh

# ─────────────────────────────────────────────
# 10. .env defaults
# ─────────────────────────────────────────────
RUN cat <<'EOF' > /app/.env
PORT=3000
DB_PATH=/app/data/gateway.db
MODEL_DIR=/app/models
LLAMA_BIN=llama-cli
NODE_ENV=production
EOF

# ─────────────────────────────────────────────
# 11. Install Node dependencies
# ─────────────────────────────────────────────
WORKDIR /app
RUN npm install --omit=dev 2>&1 | tail -5

# ─────────────────────────────────────────────
# 12. Permissions & final setup
# ─────────────────────────────────────────────
RUN mkdir -p /app/data /app/models /app/logs \
    && chmod -R 755 /app \
    && chmod +x /app/start.sh

# ─────────────────────────────────────────────
# 13. Expose & launch
# ─────────────────────────────────────────────
EXPOSE 3000

HEALTHCHECK --interval=30s --timeout=10s --start-period=60s --retries=3 \
  CMD curl -f http://localhost:3000/health || exit 1

CMD ["/app/start.sh"]
