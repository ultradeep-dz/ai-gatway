# ============================================================
# LOCAL AI GATEWAY — Production Dockerfile
# Deploy on Render.com or any Docker host
# Single-file, no external dependencies
# ============================================================
FROM ubuntu:22.04

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
    && BIN=$(find ${LLAMA_DIR}/build/bin -type f \( -name "llama-cli" -o -name "main" \) | head -1) \
    && echo "Found llama binary: $BIN" \
    && cp "$BIN" /usr/local/bin/llama-cli \
    && chmod +x /usr/local/bin/llama-cli \
    && echo "llama-cli installed OK"

# ─────────────────────────────────────────────
# 3. NODE PROJECT SCAFFOLD
# ─────────────────────────────────────────────
WORKDIR /app
RUN mkdir -p data models src logs

# ── package.json ──────────────────────────────
RUN cat <<'ENDOFFILE' > /app/package.json
{
  "name": "local-ai-gateway",
  "version": "2.0.0",
  "description": "Private, offline AI API Gateway powered by llama.cpp",
  "main": "src/server.js",
  "scripts": {
    "start": "node src/server.js"
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
ENDOFFILE

# ─────────────────────────────────────────────
# 4. roles.js
# ─────────────────────────────────────────────
RUN cat <<'ENDOFFILE' > /app/src/roles.js
const ROLES = {
  VISITOR:          { level: 0, tokenLimit: 0,     canAccessAI: false, canManageKeys: false, canViewAnalytics: false, canManageAdmins: false },
  USER:             { level: 1, tokenLimit: 500,    canAccessAI: true,  canManageKeys: false, canViewAnalytics: false, canManageAdmins: false },
  PRO_USER:         { level: 2, tokenLimit: 1000,   canAccessAI: true,  canManageKeys: false, canViewAnalytics: false, canManageAdmins: false },
  VIP_USER:         { level: 3, tokenLimit: 2000,   canAccessAI: true,  canManageKeys: false, canViewAnalytics: false, canManageAdmins: false },
  WORKER:           { level: 4, tokenLimit: 800,    canAccessAI: true,  canManageKeys: false, canViewAnalytics: false, canManageAdmins: false },
  SUPERVISOR:       { level: 5, tokenLimit: 1500,   canAccessAI: true,  canManageKeys: false, canViewAnalytics: true,  canManageAdmins: false },
  ADMIN:            { level: 6, tokenLimit: 3000,   canAccessAI: true,  canManageKeys: true,  canViewAnalytics: true,  canManageAdmins: false },
  SUPER_ADMIN:      { level: 7, tokenLimit: 5000,   canAccessAI: true,  canManageKeys: true,  canViewAnalytics: true,  canManageAdmins: true  },
  PROGRAMMER_TEAM:  { level: 8, tokenLimit: 999999, canAccessAI: true,  canManageKeys: true,  canViewAnalytics: true,  canManageAdmins: true  },
};

const ROLE_NAMES = Object.keys(ROLES);

function getRole(roleName) { return ROLES[roleName] || null; }

function hasPermission(roleName, permission) {
  const role = getRole(roleName);
  return role ? role[permission] === true : false;
}

function getTokenLimit(roleName) {
  const role = getRole(roleName);
  return role ? role.tokenLimit : 0;
}

function isValidRole(roleName) { return ROLE_NAMES.includes(roleName); }

function canRoleManage(managerRole, targetRole) {
  const mgr = getRole(managerRole);
  const tgt = getRole(targetRole);
  if (!mgr || !tgt) return false;
  return mgr.level > tgt.level;
}

module.exports = { ROLES, ROLE_NAMES, getRole, hasPermission, getTokenLimit, isValidRole, canRoleManage };
ENDOFFILE

# ─────────────────────────────────────────────
# 5. database.js
# ─────────────────────────────────────────────
RUN cat <<'ENDOFFILE' > /app/src/database.js
const Database = require('better-sqlite3');
const { v4: uuidv4 } = require('uuid');

const DB_PATH = process.env.DB_PATH || '/app/data/gateway.db';
let db;

function getDB() {
  if (!db) {
    db = new Database(DB_PATH);
    db.pragma('journal_mode = WAL');
    db.pragma('foreign_keys = ON');
  }
  return db;
}

function initSchema() {
  const database = getDB();

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

  const count = database.prepare('SELECT COUNT(*) as c FROM api_keys').get();
  if (count.c === 0) {
    const masterKey = 'gateway-master-' + uuidv4().replace(/-/g, '').substring(0, 16);
    database.prepare(
      'INSERT INTO api_keys (id, api_key, name, role, quota, enabled) VALUES (?, ?, ?, ?, ?, 1)'
    ).run(uuidv4(), masterKey, 'Master Key', 'PROGRAMMER_TEAM', 999999);
    console.log('\n====================================================');
    console.log('  MASTER API KEY GENERATED — save this immediately!');
    console.log('  KEY: ' + masterKey);
    console.log('====================================================\n');
  }
}

function createKey({ name, role, quota }) {
  const database = getDB();
  const id = uuidv4();
  const api_key = 'gw-' + uuidv4().replace(/-/g, '');
  database.prepare(
    'INSERT INTO api_keys (id, api_key, name, role, quota) VALUES (?, ?, ?, ?, ?)'
  ).run(id, api_key, name || 'Unnamed Key', role || 'USER', quota || 1000);
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
  getDB().prepare(
    "UPDATE api_keys SET used = used + ?, updated_at = datetime('now') WHERE id = ?"
  ).run(tokensUsed, id);
}

function logRequest({ api_key_id, endpoint, tokens_used, duration_ms, status }) {
  getDB().prepare(
    'INSERT INTO request_logs (id, api_key_id, endpoint, tokens_used, duration_ms, status) VALUES (?, ?, ?, ?, ?, ?)'
  ).run(uuidv4(), api_key_id, endpoint, tokens_used || 0, duration_ms || 0, status || 200);
}

function getAnalytics() {
  const database = getDB();
  return {
    totalRequests: database.prepare('SELECT COUNT(*) as c FROM request_logs').get().c,
    totalKeys: database.prepare('SELECT COUNT(*) as c FROM api_keys').get().c,
    activeKeys: database.prepare('SELECT COUNT(*) as c FROM api_keys WHERE enabled = 1').get().c,
    requestsByEndpoint: database.prepare(
      'SELECT endpoint, COUNT(*) as count, AVG(duration_ms) as avg_ms FROM request_logs GROUP BY endpoint ORDER BY count DESC'
    ).all(),
    recentRequests: database.prepare(`
      SELECT r.*, k.name as key_name, k.role
      FROM request_logs r
      LEFT JOIN api_keys k ON r.api_key_id = k.id
      ORDER BY r.created_at DESC LIMIT 20
    `).all(),
  };
}

module.exports = { getDB, initSchema, createKey, listKeys, getKeyByValue, getKeyById, deleteKey, updateKeyUsage, logRequest, getAnalytics };
ENDOFFILE

# ─────────────────────────────────────────────
# 6. ai.js
# ─────────────────────────────────────────────
RUN cat <<'ENDOFFILE' > /app/src/ai.js
const { execFile } = require('child_process');
const path = require('path');
const fs = require('fs');

const MODEL_DIR = process.env.MODEL_DIR || '/app/models';
const LLAMA_BIN = process.env.LLAMA_BIN || 'llama-cli';

const SYSTEM_PROMPTS = {
  chat:      'You are a helpful, concise AI assistant. Respond clearly and directly.',
  code:      'You are an expert programming assistant. Provide clean, well-commented code with brief explanations.',
  summarize: 'You are a summarization expert. Produce clear, concise summaries capturing key points.',
  translate: 'You are a professional translator. Translate accurately preserving tone and meaning.',
};

function findModel() {
  if (!fs.existsSync(MODEL_DIR)) return null;
  const files = fs.readdirSync(MODEL_DIR).filter(function(f) { return f.endsWith('.gguf'); });
  if (files.length === 0) return null;
  const preferred = files.find(function(f) { return f.includes('tinyllama') || f.includes('phi') || f.includes('tiny'); });
  return path.join(MODEL_DIR, preferred || files[0]);
}

function buildPrompt(type, userMessage, options) {
  const sys = SYSTEM_PROMPTS[type] || SYSTEM_PROMPTS.chat;
  let extra = '';
  if (options && options.targetLanguage) extra = '\nTarget language: ' + options.targetLanguage;
  if (options && options.codeLanguage)   extra = '\nPreferred language: ' + options.codeLanguage;
  return '<|system|>\n' + sys + extra + '<|end|>\n<|user|>\n' + userMessage + '<|end|>\n<|assistant|>';
}

function runInference(prompt, tokenLimit) {
  return new Promise(function(resolve, reject) {
    const modelPath = findModel();
    if (!modelPath) {
      return reject(new Error('No GGUF model found in ' + MODEL_DIR + '. Model may still be downloading.'));
    }

    const args = [
      '-m', modelPath,
      '-p', prompt,
      '-n', String(Math.min(tokenLimit || 500, 4096)),
      '--temp', '0.7',
      '--top-p', '0.9',
      '--repeat-penalty', '1.1',
      '-c', '2048',
      '--log-disable',
    ];

    const startTime = Date.now();

    execFile(LLAMA_BIN, args, { timeout: 120000, maxBuffer: 10 * 1024 * 1024 },
      function(error, stdout, stderr) {
        const duration = Date.now() - startTime;
        if (error && !stdout) {
          return reject(new Error('Inference error: ' + error.message));
        }
        let response = stdout || '';
        const marker = '<|assistant|>';
        const idx = response.lastIndexOf(marker);
        if (idx !== -1) response = response.substring(idx + marker.length);
        response = response
          .replace(/<\|end\|>/g, '')
          .replace(/<\|endoftext\|>/g, '')
          .replace(/\[end of text\]/gi, '')
          .trim();
        const tokens_used = Math.ceil(response.split(/\s+/).length / 0.75);
        resolve({ response: response, duration_ms: duration, tokens_used: tokens_used });
      }
    );
  });
}

function chat(message, tokenLimit)            { return runInference(buildPrompt('chat', message), tokenLimit); }
function code(message, options, tokenLimit)   { return runInference(buildPrompt('code', message, options), tokenLimit); }
function summarize(text, tokenLimit)          { return runInference(buildPrompt('summarize', 'Summarize:\n\n' + text), tokenLimit); }
function translate(text, options, tokenLimit) { return runInference(buildPrompt('translate', text, options), tokenLimit); }

function modelStatus() {
  const modelPath = findModel();
  if (!modelPath) return { ready: false, model: null };
  const stats = fs.statSync(modelPath);
  return { ready: true, model: path.basename(modelPath), size_mb: Math.round(stats.size / 1024 / 1024) };
}

module.exports = { chat: chat, code: code, summarize: summarize, translate: translate, modelStatus: modelStatus };
ENDOFFILE

# ─────────────────────────────────────────────
# 7. middleware.js
# ─────────────────────────────────────────────
RUN cat <<'ENDOFFILE' > /app/src/middleware.js
const { getKeyByValue } = require('./database');
const { hasPermission, getTokenLimit } = require('./roles');

function authenticate(req, res, next) {
  const apiKey = req.headers['x-api-key'];
  if (!apiKey) {
    return res.status(401).json({ error: 'Unauthorized', message: 'Missing x-api-key header' });
  }
  const keyRecord = getKeyByValue(apiKey);
  if (!keyRecord) {
    return res.status(401).json({ error: 'Unauthorized', message: 'Invalid or disabled API key' });
  }
  if (keyRecord.quota > 0 && keyRecord.used >= keyRecord.quota) {
    return res.status(429).json({
      error: 'Quota Exceeded',
      message: 'Token quota exhausted for this key',
      used: keyRecord.used,
      quota: keyRecord.quota,
    });
  }
  req.apiKey = keyRecord;
  req.tokenLimit = getTokenLimit(keyRecord.role);
  next();
}

function requirePermission(permission) {
  return function(req, res, next) {
    if (!req.apiKey) return res.status(401).json({ error: 'Unauthorized' });
    if (!hasPermission(req.apiKey.role, permission)) {
      return res.status(403).json({
        error: 'Forbidden',
        message: 'Role ' + req.apiKey.role + ' lacks permission: ' + permission,
      });
    }
    next();
  };
}

function requireAIAccess(req, res, next) {
  if (!req.apiKey) return res.status(401).json({ error: 'Unauthorized' });
  if (!hasPermission(req.apiKey.role, 'canAccessAI')) {
    return res.status(403).json({ error: 'Forbidden', message: 'Your role does not have AI access', role: req.apiKey.role });
  }
  if (req.tokenLimit <= 0) {
    return res.status(403).json({ error: 'Forbidden', message: 'No token limit configured for your role' });
  }
  next();
}

module.exports = { authenticate: authenticate, requirePermission: requirePermission, requireAIAccess: requireAIAccess };
ENDOFFILE

# ─────────────────────────────────────────────
# 8. server.js
# ─────────────────────────────────────────────
RUN cat <<'ENDOFFILE' > /app/src/server.js
require('dotenv').config();
const express   = require('express');
const helmet    = require('helmet');
const morgan    = require('morgan');
const rateLimit = require('express-rate-limit');

const db        = require('./database');
const mw        = require('./middleware');
const ai        = require('./ai');
const roles     = require('./roles');

const app  = express();
const PORT = process.env.PORT || 3000;
const START = Date.now();

app.use(helmet());
app.use(express.json({ limit: '2mb' }));
app.use(morgan('combined'));
app.use(rateLimit({ windowMs: 60000, max: 120, message: { error: 'Rate limit exceeded' } }));

db.initSchema();

// Health
app.get('/', function(req, res) {
  res.json({
    service: 'Local AI Gateway',
    version: '2.0.0',
    status: 'operational',
    uptime_seconds: Math.floor((Date.now() - START) / 1000),
    model: ai.modelStatus(),
    timestamp: new Date().toISOString(),
    endpoints: {
      health:    'GET  /',
      chat:      'POST /ai/chat',
      code:      'POST /ai/code',
      summarize: 'POST /ai/summarize',
      translate: 'POST /ai/translate',
      createKey: 'POST /admin/create-key',
      listKeys:  'GET  /admin/keys',
      deleteKey: 'DELETE /admin/key/:id',
      analytics: 'GET  /admin/analytics',
    },
  });
});

app.get('/health', function(req, res) {
  res.json({ status: 'ok', model: ai.modelStatus() });
});

// AI helper wrapper
function aiEndpoint(req, res, fn, name) {
  var t0 = Date.now();
  fn().then(function(result) {
    db.updateKeyUsage(req.apiKey.id, result.tokens_used || 0);
    db.logRequest({ api_key_id: req.apiKey.id, endpoint: name, tokens_used: result.tokens_used, duration_ms: Date.now() - t0, status: 200 });
    res.json({ success: true, response: result.response, meta: { tokens_used: result.tokens_used, duration_ms: result.duration_ms, role: req.apiKey.role, token_limit: req.tokenLimit } });
  }).catch(function(err) {
    db.logRequest({ api_key_id: req.apiKey.id, endpoint: name, duration_ms: Date.now() - t0, status: 500 });
    console.error('[' + name + ']', err.message);
    res.status(500).json({ error: 'AI inference failed', message: err.message });
  });
}

// AI endpoints
app.post('/ai/chat', mw.authenticate, mw.requireAIAccess, function(req, res) {
  var message = req.body.message;
  if (!message || !message.trim()) return res.status(400).json({ error: 'Bad Request', message: '"message" is required' });
  aiEndpoint(req, res, function() { return ai.chat(message.trim(), req.tokenLimit); }, '/ai/chat');
});

app.post('/ai/code', mw.authenticate, mw.requireAIAccess, function(req, res) {
  var message = req.body.message;
  var language = req.body.language;
  if (!message || !message.trim()) return res.status(400).json({ error: 'Bad Request', message: '"message" is required' });
  aiEndpoint(req, res, function() { return ai.code(message.trim(), { codeLanguage: language }, req.tokenLimit); }, '/ai/code');
});

app.post('/ai/summarize', mw.authenticate, mw.requireAIAccess, function(req, res) {
  var text = req.body.text;
  if (!text || !text.trim()) return res.status(400).json({ error: 'Bad Request', message: '"text" is required' });
  aiEndpoint(req, res, function() { return ai.summarize(text.trim(), req.tokenLimit); }, '/ai/summarize');
});

app.post('/ai/translate', mw.authenticate, mw.requireAIAccess, function(req, res) {
  var text = req.body.text;
  var targetLanguage = req.body.targetLanguage;
  if (!text || !text.trim()) return res.status(400).json({ error: 'Bad Request', message: '"text" is required' });
  aiEndpoint(req, res, function() { return ai.translate(text.trim(), { targetLanguage: targetLanguage }, req.tokenLimit); }, '/ai/translate');
});

// Admin endpoints
app.post('/admin/create-key', mw.authenticate, mw.requirePermission('canManageKeys'), function(req, res) {
  var name  = req.body.name;
  var role  = req.body.role;
  var quota = req.body.quota;
  if (role && !roles.isValidRole(role)) return res.status(400).json({ error: 'Invalid role', valid_roles: roles.ROLE_NAMES });
  if (role && req.apiKey.role !== 'PROGRAMMER_TEAM' && !roles.canRoleManage(req.apiKey.role, role)) {
    return res.status(403).json({ error: 'Forbidden', message: 'Cannot create keys with role ' + role });
  }
  var newKey = db.createKey({ name: name, role: role || 'USER', quota: quota || 1000 });
  res.status(201).json({ success: true, message: 'API key created', key: newKey });
});

app.get('/admin/keys', mw.authenticate, mw.requirePermission('canManageKeys'), function(req, res) {
  var keys = db.listKeys().map(function(k) {
    return Object.assign({}, k, {
      api_key: req.apiKey.role === 'PROGRAMMER_TEAM'
        ? k.api_key
        : k.api_key.substring(0, 8) + '...' + k.api_key.slice(-4),
    });
  });
  res.json({ success: true, count: keys.length, keys: keys });
});

app.delete('/admin/key/:id', mw.authenticate, mw.requirePermission('canManageKeys'), function(req, res) {
  var id = req.params.id;
  if (id === req.apiKey.id) return res.status(400).json({ error: 'Cannot delete your own key' });
  var target = db.getKeyById(id);
  if (!target) return res.status(404).json({ error: 'Key not found' });
  if (req.apiKey.role !== 'PROGRAMMER_TEAM' && !roles.canRoleManage(req.apiKey.role, target.role)) {
    return res.status(403).json({ error: 'Forbidden', message: 'Insufficient role to delete this key' });
  }
  var deleted = db.deleteKey(id);
  res.json({ success: deleted, message: deleted ? 'Key deleted' : 'Not found' });
});

app.get('/admin/analytics', mw.authenticate, mw.requirePermission('canViewAnalytics'), function(req, res) {
  res.json({ success: true, analytics: db.getAnalytics() });
});

// Fallbacks
app.use(function(req, res) { res.status(404).json({ error: 'Not Found', path: req.path }); });
app.use(function(err, req, res, next) { console.error(err); res.status(500).json({ error: 'Internal Server Error' }); });

app.listen(PORT, '0.0.0.0', function() {
  console.log('Local AI Gateway running on port ' + PORT);
  console.log('Model: ' + JSON.stringify(ai.modelStatus()));
});
ENDOFFILE

# ─────────────────────────────────────────────
# 9. start.sh — written AND chmod in ONE RUN block
# ─────────────────────────────────────────────
RUN cat <<'ENDOFFILE' > /app/start.sh && chmod +x /app/start.sh
#!/bin/bash
set -e

echo "============================================"
echo "       Local AI Gateway  v2.0               "
echo "============================================"

MODEL_DIR="${MODEL_DIR:-/app/models}"
MODEL_FILE="${MODEL_DIR}/tinyllama-1.1b-chat-v1.0.Q4_K_M.gguf"
MODEL_URL="https://huggingface.co/TheBloke/TinyLlama-1.1B-Chat-v1.0-GGUF/resolve/main/tinyllama-1.1b-chat-v1.0.Q4_K_M.gguf"

mkdir -p "${MODEL_DIR}" /app/data /app/logs

if [ ! -f "${MODEL_FILE}" ]; then
  echo "Downloading TinyLlama 1.1B Q4_K_M (~700MB) - first run only..."
  wget --progress=bar:force:noscroll -O "${MODEL_FILE}.tmp" "${MODEL_URL}" \
    && mv "${MODEL_FILE}.tmp" "${MODEL_FILE}" \
    && echo "Model downloaded OK." \
    || {
      echo "Primary download failed. Trying Phi-3 Mini fallback..."
      PHI_FILE="${MODEL_DIR}/phi-3-mini.Q4_K_M.gguf"
      PHI_URL="https://huggingface.co/microsoft/Phi-3-mini-4k-instruct-gguf/resolve/main/Phi-3-mini-4k-instruct-q4.gguf"
      wget --progress=bar:force:noscroll -O "${PHI_FILE}.tmp" "${PHI_URL}" \
        && mv "${PHI_FILE}.tmp" "${PHI_FILE}" \
        && echo "Phi-3 Mini downloaded OK." \
        || echo "WARNING: Model download failed. AI endpoints unavailable until a model is present."
    }
else
  echo "Model ready: $(basename ${MODEL_FILE})"
fi

if ! command -v llama-cli &> /dev/null; then
  echo "ERROR: llama-cli not found in PATH"
  exit 1
fi

echo "Starting Node.js API server on port ${PORT:-3000}..."
cd /app
exec node src/server.js
ENDOFFILE

# ─────────────────────────────────────────────
# 10. .env defaults
# ─────────────────────────────────────────────
RUN cat <<'ENDOFFILE' > /app/.env
PORT=3000
DB_PATH=/app/data/gateway.db
MODEL_DIR=/app/models
LLAMA_BIN=llama-cli
NODE_ENV=production
ENDOFFILE

# ─────────────────────────────────────────────
# 11. Install Node dependencies
# ─────────────────────────────────────────────
WORKDIR /app
RUN npm install --omit=dev

# ─────────────────────────────────────────────
# 12. Final permissions
# ─────────────────────────────────────────────
RUN mkdir -p /app/data /app/models /app/logs \
    && chmod -R 755 /app \
    && chmod +x /app/start.sh

# ─────────────────────────────────────────────
# 13. Expose & launch
# ─────────────────────────────────────────────
EXPOSE 3000

HEALTHCHECK --interval=30s --timeout=10s --start-period=120s --retries=3 \
  CMD curl -f http://localhost:3000/health || exit 1

CMD ["/bin/bash", "/app/start.sh"]
