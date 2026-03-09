import fs from 'node:fs';
import { randomUUID } from 'node:crypto';
import { Low } from 'lowdb';
import { JSONFile } from 'lowdb/node';

function nowISO() {
  return new Date().toISOString();
}

const defaultState = {
  users: [],
  magicLinks: [],
  orders: [],
  payments: [],
  licenses: [],
  activations: [],
  auditLogs: []
};

function normalizeEmail(value) {
  return String(value || '').trim().toLowerCase();
}

function id(prefix) {
  return `${prefix}_${randomUUID().replace(/-/g, '')}`;
}

export async function createStore(storePath) {
  const dir = storePath.split('/').slice(0, -1).join('/');
  if (dir) {
    fs.mkdirSync(dir, { recursive: true });
  }

  const adapter = new JSONFile(storePath);
  const db = new Low(adapter, structuredClone(defaultState));
  await db.read();
  db.data ||= structuredClone(defaultState);
  await db.write();

  async function commit() {
    await db.write();
  }

  function userRoleForEmail(email, isAdminEmail) {
    return isAdminEmail(email) ? 'admin' : 'customer';
  }

  async function ensureUser(email, isAdminEmail) {
    const normalized = normalizeEmail(email);
    if (!normalized) {
      throw new Error('Email is required');
    }

    let user = db.data.users.find(item => item.email === normalized);
    const desiredRole = userRoleForEmail(normalized, isAdminEmail);

    if (!user) {
      user = {
        id: id('usr'),
        email: normalized,
        role: desiredRole,
        createdAt: nowISO()
      };
      db.data.users.push(user);
      await commit();
      return user;
    }

    if (desiredRole === 'admin' && user.role !== 'admin') {
      user.role = 'admin';
      await commit();
    }

    return user;
  }

  function getUserByID(userID) {
    return db.data.users.find(item => item.id === userID) || null;
  }

  async function createMagicLink({ userID, tokenHash, expiresAt }) {
    const record = {
      id: id('mlk'),
      userID,
      tokenHash,
      expiresAt,
      usedAt: null,
      createdAt: nowISO()
    };
    db.data.magicLinks.push(record);
    await commit();
    return record;
  }

  async function consumeMagicLink(tokenHash) {
    const record = db.data.magicLinks.find(item => item.tokenHash === tokenHash);
    if (!record) {
      return null;
    }
    if (record.usedAt) {
      return null;
    }
    if (Date.parse(record.expiresAt) < Date.now()) {
      return null;
    }
    record.usedAt = nowISO();
    await commit();
    return record;
  }

  function findOrderBySessionID(sessionID) {
    return db.data.orders.find(item => item.providerSessionID === sessionID) || null;
  }

  async function createOrder(input) {
    const record = {
      id: id('ord'),
      userID: input.userID,
      provider: input.provider,
      providerSessionID: input.providerSessionID || null,
      providerPaymentID: input.providerPaymentID || null,
      amountCents: Number(input.amountCents || 0),
      currency: (input.currency || 'usd').toLowerCase(),
      status: input.status || 'pending',
      createdAt: nowISO(),
      updatedAt: nowISO()
    };
    db.data.orders.push(record);
    await commit();
    return record;
  }

  async function upsertPaymentEvent(input) {
    if (input.providerEventID) {
      const existing = db.data.payments.find(item => item.providerEventID === input.providerEventID);
      if (existing) {
        return { event: existing, inserted: false };
      }
    }

    const record = {
      id: id('pay'),
      orderID: input.orderID || null,
      providerEventID: input.providerEventID || null,
      type: input.type || 'unknown',
      amountCents: Number(input.amountCents || 0),
      currency: (input.currency || 'usd').toLowerCase(),
      rawPayload: input.rawPayload || null,
      createdAt: nowISO()
    };
    db.data.payments.push(record);
    await commit();
    return { event: record, inserted: true };
  }

  function findLicenseByOrderID(orderID) {
    return db.data.licenses.find(item => item.orderID === orderID) || null;
  }

  function findLicenseByKey(key) {
    const normalized = String(key || '').trim();
    return db.data.licenses.find(item => item.key === normalized) || null;
  }

  async function createLicense(input) {
    const record = {
      id: id('lic'),
      userID: input.userID,
      orderID: input.orderID,
      key: input.key,
      plan: input.plan || 'pro_lifetime',
      entitlements: Array.isArray(input.entitlements) ? input.entitlements : ['recording'],
      expiresAt: input.expiresAt || null,
      revoked: Boolean(input.revoked),
      createdAt: nowISO(),
      updatedAt: nowISO()
    };
    db.data.licenses.push(record);
    await commit();
    return record;
  }

  async function regenerateLicense(licenseID, nextKey) {
    const record = db.data.licenses.find(item => item.id === licenseID);
    if (!record) {
      return null;
    }
    record.key = nextKey;
    record.updatedAt = nowISO();
    await commit();
    return record;
  }

  async function updateLicenseRevoked(licenseID, revoked) {
    const record = db.data.licenses.find(item => item.id === licenseID);
    if (!record) {
      return null;
    }
    record.revoked = Boolean(revoked);
    record.updatedAt = nowISO();
    await commit();
    return record;
  }

  async function recordActivation(input) {
    const record = {
      id: id('act'),
      licenseID: input.licenseID,
      deviceID: input.deviceID || null,
      appVersion: input.appVersion || null,
      ipHash: input.ipHash || null,
      validatedAt: nowISO()
    };
    db.data.activations.push(record);
    await commit();
    return record;
  }

  async function recordAudit(input) {
    const record = {
      id: id('log'),
      actorUserID: input.actorUserID || null,
      action: input.action,
      targetType: input.targetType,
      targetID: input.targetID,
      metadata: input.metadata || {},
      createdAt: nowISO()
    };
    db.data.auditLogs.push(record);
    await commit();
    return record;
  }

  function listOrdersForUser(userID) {
    return db.data.orders
      .filter(item => item.userID === userID)
      .sort((left, right) => right.createdAt.localeCompare(left.createdAt));
  }

  function listLicensesForUser(userID) {
    return db.data.licenses
      .filter(item => item.userID === userID)
      .sort((left, right) => right.createdAt.localeCompare(left.createdAt));
  }

  function listActivationsForLicense(licenseID) {
    return db.data.activations
      .filter(item => item.licenseID === licenseID)
      .sort((left, right) => right.validatedAt.localeCompare(left.validatedAt));
  }

  function listAdminOrders() {
    return [...db.data.orders].sort((left, right) => right.createdAt.localeCompare(left.createdAt));
  }

  function listAdminPayments() {
    return [...db.data.payments].sort((left, right) => right.createdAt.localeCompare(left.createdAt));
  }

  function listAdminLicenses() {
    return [...db.data.licenses].sort((left, right) => right.createdAt.localeCompare(left.createdAt));
  }

  return {
    ensureUser,
    getUserByID,
    createMagicLink,
    consumeMagicLink,
    findOrderBySessionID,
    createOrder,
    upsertPaymentEvent,
    findLicenseByOrderID,
    findLicenseByKey,
    createLicense,
    regenerateLicense,
    updateLicenseRevoked,
    recordActivation,
    recordAudit,
    listOrdersForUser,
    listLicensesForUser,
    listActivationsForLicense,
    listAdminOrders,
    listAdminPayments,
    listAdminLicenses
  };
}
