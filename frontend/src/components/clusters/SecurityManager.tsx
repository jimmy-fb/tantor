import { useState, useEffect, useCallback } from 'react';
import {
  Shield, ShieldOff, Plus, Trash2, RefreshCw, Loader2, AlertCircle,
  UserPlus, RotateCw, Copy, Eye, EyeOff, Lock, Clock, Check,
  ChevronDown, ChevronUp, Search, Filter,
} from 'lucide-react';
import type {
  KafkaUserInfo, KafkaUserCreatedResponse, KafkaUserRotateResponse,
  AclEntry, AuditLogEntry,
} from '../../types';
import {
  getKafkaUsers, createKafkaUser, deleteKafkaUser, rotateKafkaUserPassword,
  getAcls, createAcl, deleteAcl,
  getAuditLog,
} from '../../lib/api';

interface Props {
  clusterId: string;
}

type SecurityTab = 'users' | 'acls' | 'audit';

const OPERATIONS = ['Read', 'Write', 'Create', 'Describe', 'Alter', 'Delete', 'All'];
const RESOURCE_TYPES = ['topic', 'group', 'cluster', 'transactional-id'];

const ACTION_COLORS: Record<string, string> = {
  user_created: 'bg-green-100 text-green-800',
  user_deleted: 'bg-red-100 text-red-800',
  user_password_rotated: 'bg-blue-100 text-blue-800',
  acl_created: 'bg-green-100 text-green-800',
  acl_deleted: 'bg-red-100 text-red-800',
};

export default function SecurityManager({ clusterId }: Props) {
  const [activeTab, setActiveTab] = useState<SecurityTab>('users');

  // ── Users state ──
  const [users, setUsers] = useState<KafkaUserInfo[]>([]);
  const [usersLoading, setUsersLoading] = useState(false);
  const [usersError, setUsersError] = useState('');
  const [showCreateUser, setShowCreateUser] = useState(false);
  const [newUsername, setNewUsername] = useState('');
  const [newPassword, setNewPassword] = useState('');
  const [autoGenerate, setAutoGenerate] = useState(true);
  const [mechanism, setMechanism] = useState('SCRAM-SHA-256');
  const [creating, setCreating] = useState(false);
  const [createdUser, setCreatedUser] = useState<KafkaUserCreatedResponse | null>(null);
  const [showPassword, setShowPassword] = useState(false);
  const [copied, setCopied] = useState(false);
  const [rotatingUser, setRotatingUser] = useState<string | null>(null);
  const [rotatePassword, setRotatePassword] = useState('');
  const [rotateAutoGen, setRotateAutoGen] = useState(true);
  const [rotatedResult, setRotatedResult] = useState<KafkaUserRotateResponse | null>(null);
  const [actionLoading, setActionLoading] = useState<string | null>(null);

  // ── ACLs state ──
  const [acls, setAcls] = useState<AclEntry[]>([]);
  const [aclsLoading, setAclsLoading] = useState(false);
  const [aclsError, setAclsError] = useState('');
  const [showCreateAcl, setShowCreateAcl] = useState(false);
  const [aclPrincipal, setAclPrincipal] = useState('');
  const [aclResourceType, setAclResourceType] = useState('topic');
  const [aclResourceName, setAclResourceName] = useState('');
  const [aclPatternType, setAclPatternType] = useState('literal');
  const [aclOperations, setAclOperations] = useState<string[]>([]);
  const [aclPermission, setAclPermission] = useState('Allow');
  const [aclHost, setAclHost] = useState('*');
  const [aclCreating, setAclCreating] = useState(false);
  const [aclFilterPrincipal, setAclFilterPrincipal] = useState('');
  const [aclFilterResource, setAclFilterResource] = useState('');

  // ── Audit state ──
  const [auditLogs, setAuditLogs] = useState<AuditLogEntry[]>([]);
  const [auditLoading, setAuditLoading] = useState(false);
  const [auditFilter, setAuditFilter] = useState('');
  const [expandedLog, setExpandedLog] = useState<string | null>(null);

  // ── Data fetching ──

  const fetchUsers = useCallback(async () => {
    setUsersLoading(true);
    setUsersError('');
    try {
      const data = await getKafkaUsers(clusterId);
      setUsers(data);
    } catch (err: unknown) {
      const msg = err instanceof Error ? err.message : 'Failed to load users';
      const axErr = err as { response?: { data?: { detail?: string } } };
      setUsersError(axErr.response?.data?.detail || msg);
    } finally {
      setUsersLoading(false);
    }
  }, [clusterId]);

  const fetchAcls = useCallback(async () => {
    setAclsLoading(true);
    setAclsError('');
    try {
      const data = await getAcls(clusterId);
      setAcls(data.acls);
    } catch (err: unknown) {
      const msg = err instanceof Error ? err.message : 'Failed to load ACLs';
      const axErr = err as { response?: { data?: { detail?: string } } };
      setAclsError(axErr.response?.data?.detail || msg);
    } finally {
      setAclsLoading(false);
    }
  }, [clusterId]);

  const fetchAuditLog = useCallback(async () => {
    setAuditLoading(true);
    try {
      const data = await getAuditLog(clusterId, {
        limit: 100,
        ...(auditFilter ? { action: auditFilter } : {}),
      });
      setAuditLogs(data);
    } catch {
      // Audit log errors are non-critical
    } finally {
      setAuditLoading(false);
    }
  }, [clusterId, auditFilter]);

  useEffect(() => {
    if (activeTab === 'users') fetchUsers();
    else if (activeTab === 'acls') fetchAcls();
    else if (activeTab === 'audit') fetchAuditLog();
  }, [activeTab, fetchUsers, fetchAcls, fetchAuditLog]);

  // ── User actions ──

  const handleCreateUser = async () => {
    if (!newUsername.trim()) return;
    setCreating(true);
    setUsersError('');
    try {
      const result = await createKafkaUser(clusterId, {
        username: newUsername.trim(),
        password: autoGenerate ? undefined : newPassword,
        mechanism,
      });
      setCreatedUser(result);
      setShowCreateUser(false);
      setNewUsername('');
      setNewPassword('');
      setAutoGenerate(true);
      fetchUsers();
    } catch (err: unknown) {
      const axErr = err as { response?: { data?: { detail?: string } } };
      setUsersError(axErr.response?.data?.detail || 'Failed to create user');
    } finally {
      setCreating(false);
    }
  };

  const handleDeleteUser = async (username: string) => {
    if (!confirm(`Delete Kafka user "${username}"? This will remove their SCRAM credentials.`)) return;
    setActionLoading(username);
    try {
      await deleteKafkaUser(clusterId, username);
      fetchUsers();
    } catch (err: unknown) {
      const axErr = err as { response?: { data?: { detail?: string } } };
      setUsersError(axErr.response?.data?.detail || 'Failed to delete user');
    } finally {
      setActionLoading(null);
    }
  };

  const handleRotate = async (username: string) => {
    setActionLoading(`rotate-${username}`);
    try {
      const result = await rotateKafkaUserPassword(clusterId, username, {
        password: rotateAutoGen ? undefined : rotatePassword,
      });
      setRotatedResult(result);
      setRotatingUser(null);
      setRotatePassword('');
      setRotateAutoGen(true);
      fetchUsers();
    } catch (err: unknown) {
      const axErr = err as { response?: { data?: { detail?: string } } };
      setUsersError(axErr.response?.data?.detail || 'Failed to rotate password');
    } finally {
      setActionLoading(null);
    }
  };

  const copyToClipboard = (text: string) => {
    navigator.clipboard.writeText(text);
    setCopied(true);
    setTimeout(() => setCopied(false), 2000);
  };

  // ── ACL actions ──

  const toggleOperation = (op: string) => {
    setAclOperations(prev =>
      prev.includes(op) ? prev.filter(o => o !== op) : [...prev, op]
    );
  };

  const handleCreateAcl = async () => {
    if (!aclPrincipal.trim() || aclOperations.length === 0) return;
    setAclCreating(true);
    setAclsError('');
    try {
      await createAcl(clusterId, {
        principal: aclPrincipal.trim(),
        resource_type: aclResourceType,
        resource_name: aclResourceName.trim(),
        pattern_type: aclPatternType,
        operations: aclOperations,
        permission_type: aclPermission,
        host: aclHost || '*',
      });
      setShowCreateAcl(false);
      setAclPrincipal('');
      setAclResourceName('');
      setAclOperations([]);
      setAclHost('*');
      fetchAcls();
    } catch (err: unknown) {
      const axErr = err as { response?: { data?: { detail?: string } } };
      setAclsError(axErr.response?.data?.detail || 'Failed to create ACL');
    } finally {
      setAclCreating(false);
    }
  };

  const handleDeleteAcl = async (acl: AclEntry) => {
    if (!confirm(`Remove ${acl.permission_type} ${acl.operation} for ${acl.principal} on ${acl.resource_type}:${acl.resource_name}?`)) return;
    setActionLoading(`acl-${acl.principal}-${acl.operation}-${acl.resource_name}`);
    try {
      await deleteAcl(clusterId, {
        principal: acl.principal,
        resource_type: acl.resource_type,
        resource_name: acl.resource_name,
        pattern_type: acl.pattern_type,
        operations: [acl.operation],
        permission_type: acl.permission_type,
        host: acl.host,
      });
      fetchAcls();
    } catch (err: unknown) {
      const axErr = err as { response?: { data?: { detail?: string } } };
      setAclsError(axErr.response?.data?.detail || 'Failed to delete ACL');
    } finally {
      setActionLoading(null);
    }
  };

  // ── Filtered ACLs ──
  const filteredAcls = acls.filter(acl => {
    if (aclFilterPrincipal && !acl.principal.toLowerCase().includes(aclFilterPrincipal.toLowerCase())) return false;
    if (aclFilterResource && !acl.resource_name.toLowerCase().includes(aclFilterResource.toLowerCase())) return false;
    return true;
  });

  // ── Tab bar ──
  const tabs: Array<{ id: SecurityTab; label: string; icon: React.ReactNode }> = [
    { id: 'users', label: 'Users', icon: <UserPlus size={14} /> },
    { id: 'acls', label: 'ACLs', icon: <Lock size={14} /> },
    { id: 'audit', label: 'Audit Log', icon: <Clock size={14} /> },
  ];

  return (
    <div className="space-y-4">
      {/* Auth Mode Toggle */}
      <div className="flex items-center gap-3 mb-2">
        <div className="flex rounded-lg border border-gray-200 overflow-hidden">
          <button className="px-4 py-2 text-sm font-medium bg-blue-600 text-white flex items-center gap-1.5">
            <Shield size={14} /> SASL/SCRAM
          </button>
          <button
            className="px-4 py-2 text-sm font-medium bg-gray-100 text-gray-400 cursor-not-allowed flex items-center gap-1.5"
            disabled
          >
            <ShieldOff size={14} /> mTLS
            <span className="text-[10px] bg-gray-200 text-gray-500 rounded px-1.5 py-0.5 ml-1">Coming Soon</span>
          </button>
        </div>
      </div>

      {/* Sub-tab bar */}
      <div className="flex border-b border-gray-200">
        {tabs.map(tab => (
          <button
            key={tab.id}
            onClick={() => setActiveTab(tab.id)}
            className={`flex items-center gap-1.5 px-4 py-2.5 text-sm font-medium border-b-2 transition-colors ${
              activeTab === tab.id
                ? 'border-blue-600 text-blue-600'
                : 'border-transparent text-gray-500 hover:text-gray-700'
            }`}
          >
            {tab.icon} {tab.label}
          </button>
        ))}
      </div>

      {/* ══════════ USERS TAB ══════════ */}
      {activeTab === 'users' && (
        <div>
          {/* Created user banner */}
          {createdUser && (
            <div className="bg-green-50 border border-green-200 rounded-xl p-4 mb-4">
              <div className="flex items-center justify-between mb-2">
                <span className="text-sm font-medium text-green-800">
                  User &quot;{createdUser.username}&quot; created successfully ({createdUser.mechanism})
                </span>
                <button onClick={() => setCreatedUser(null)} className="text-green-600 hover:text-green-800">
                  &times;
                </button>
              </div>
              <div className="flex items-center gap-2">
                <label className="text-xs text-green-700 font-medium">Password (shown once):</label>
                <code className="bg-green-100 px-3 py-1.5 rounded text-sm font-mono text-green-900 select-all">
                  {showPassword ? createdUser.password : '••••••••••••••••'}
                </code>
                <button onClick={() => setShowPassword(!showPassword)} className="text-green-600 hover:text-green-800">
                  {showPassword ? <EyeOff size={14} /> : <Eye size={14} />}
                </button>
                <button
                  onClick={() => copyToClipboard(createdUser.password)}
                  className="text-green-600 hover:text-green-800 flex items-center gap-1 text-xs"
                >
                  {copied ? <Check size={14} /> : <Copy size={14} />}
                  {copied ? 'Copied!' : 'Copy'}
                </button>
              </div>
            </div>
          )}

          {/* Rotated password banner */}
          {rotatedResult && (
            <div className="bg-blue-50 border border-blue-200 rounded-xl p-4 mb-4">
              <div className="flex items-center justify-between mb-2">
                <span className="text-sm font-medium text-blue-800">
                  Password rotated for &quot;{rotatedResult.username}&quot;
                </span>
                <button onClick={() => setRotatedResult(null)} className="text-blue-600 hover:text-blue-800">
                  &times;
                </button>
              </div>
              <div className="flex items-center gap-2">
                <label className="text-xs text-blue-700 font-medium">New Password:</label>
                <code className="bg-blue-100 px-3 py-1.5 rounded text-sm font-mono text-blue-900 select-all">
                  {showPassword ? rotatedResult.password : '••••••••••••••••'}
                </code>
                <button onClick={() => setShowPassword(!showPassword)} className="text-blue-600 hover:text-blue-800">
                  {showPassword ? <EyeOff size={14} /> : <Eye size={14} />}
                </button>
                <button
                  onClick={() => copyToClipboard(rotatedResult.password)}
                  className="text-blue-600 hover:text-blue-800 flex items-center gap-1 text-xs"
                >
                  {copied ? <Check size={14} /> : <Copy size={14} />}
                  {copied ? 'Copied!' : 'Copy'}
                </button>
              </div>
            </div>
          )}

          {/* Error banner */}
          {usersError && (
            <div className="flex items-center gap-2 bg-red-50 border border-red-200 rounded-lg px-4 py-3 mb-4 text-sm text-red-700">
              <AlertCircle size={16} />
              <span>{usersError}</span>
              <button onClick={fetchUsers} className="ml-auto text-xs underline">Retry</button>
            </div>
          )}

          {/* Actions bar */}
          <div className="flex items-center gap-2 mb-4">
            <button
              onClick={() => { setShowCreateUser(true); setCreatedUser(null); setRotatedResult(null); }}
              className="flex items-center gap-1.5 px-3 py-2 bg-blue-600 text-white rounded-lg text-sm hover:bg-blue-700"
            >
              <Plus size={14} /> Create User
            </button>
            <button
              onClick={fetchUsers}
              disabled={usersLoading}
              className="flex items-center gap-1.5 px-3 py-2 border border-gray-300 rounded-lg text-sm hover:bg-gray-50"
            >
              <RefreshCw size={14} className={usersLoading ? 'animate-spin' : ''} /> Refresh
            </button>
          </div>

          {/* Create user form */}
          {showCreateUser && (
            <div className="bg-blue-50 border border-blue-200 rounded-xl p-4 mb-4">
              <h4 className="text-sm font-medium text-blue-900 mb-3">Create SCRAM User</h4>
              <div className="grid grid-cols-2 gap-3">
                <div>
                  <label className="text-xs text-gray-600 mb-1 block">Username</label>
                  <input
                    type="text"
                    value={newUsername}
                    onChange={e => setNewUsername(e.target.value)}
                    placeholder="kafka-user"
                    className="w-full px-3 py-2 border rounded-lg text-sm focus:ring-2 focus:ring-blue-500"
                  />
                </div>
                <div>
                  <label className="text-xs text-gray-600 mb-1 block">Mechanism</label>
                  <select
                    value={mechanism}
                    onChange={e => setMechanism(e.target.value)}
                    className="w-full px-3 py-2 border rounded-lg text-sm focus:ring-2 focus:ring-blue-500"
                  >
                    <option value="SCRAM-SHA-256">SCRAM-SHA-256</option>
                    <option value="SCRAM-SHA-512">SCRAM-SHA-512</option>
                  </select>
                </div>
              </div>
              <div className="mt-3">
                <label className="flex items-center gap-2 text-sm text-gray-600 mb-2">
                  <input
                    type="checkbox"
                    checked={autoGenerate}
                    onChange={e => setAutoGenerate(e.target.checked)}
                    className="rounded border-gray-300 text-blue-600"
                  />
                  Auto-generate secure password
                </label>
                {!autoGenerate && (
                  <input
                    type="text"
                    value={newPassword}
                    onChange={e => setNewPassword(e.target.value)}
                    placeholder="Enter password"
                    className="w-full px-3 py-2 border rounded-lg text-sm font-mono focus:ring-2 focus:ring-blue-500"
                  />
                )}
              </div>
              <div className="flex gap-2 mt-3">
                <button
                  onClick={handleCreateUser}
                  disabled={creating || !newUsername.trim() || (!autoGenerate && !newPassword)}
                  className="flex items-center gap-1.5 px-4 py-2 bg-blue-600 text-white rounded-lg text-sm hover:bg-blue-700 disabled:opacity-50"
                >
                  {creating ? <Loader2 size={14} className="animate-spin" /> : <UserPlus size={14} />}
                  Create
                </button>
                <button
                  onClick={() => setShowCreateUser(false)}
                  className="px-4 py-2 border border-gray-300 rounded-lg text-sm hover:bg-gray-50"
                >
                  Cancel
                </button>
              </div>
            </div>
          )}

          {/* Users table */}
          {usersLoading && !users.length ? (
            <div className="flex items-center justify-center gap-2 py-8 text-gray-400 text-sm">
              <Loader2 size={16} className="animate-spin" /> Loading users...
            </div>
          ) : users.length === 0 ? (
            <div className="text-center py-12 text-gray-400 text-sm">
              <Shield size={32} className="mx-auto mb-2 opacity-50" />
              No SCRAM users configured. Create one to get started.
            </div>
          ) : (
            <div className="overflow-x-auto">
              <table className="w-full text-sm">
                <thead>
                  <tr className="bg-gray-50 text-left text-xs text-gray-500 uppercase">
                    <th className="px-4 py-3">Username</th>
                    <th className="px-4 py-3">Mechanism</th>
                    <th className="px-4 py-3">Created</th>
                    <th className="px-4 py-3">Updated</th>
                    <th className="px-4 py-3 text-right">Actions</th>
                  </tr>
                </thead>
                <tbody className="divide-y divide-gray-100">
                  {users.map(user => (
                    <tr key={user.username} className="hover:bg-gray-50">
                      <td className="px-4 py-3 font-mono font-medium">{user.username}</td>
                      <td className="px-4 py-3">
                        <span className="px-2 py-0.5 bg-purple-100 text-purple-800 rounded text-xs">
                          {user.mechanism}
                        </span>
                      </td>
                      <td className="px-4 py-3 text-gray-500 text-xs">
                        {user.created_at ? new Date(user.created_at).toLocaleString() : '—'}
                      </td>
                      <td className="px-4 py-3 text-gray-500 text-xs">
                        {user.updated_at ? new Date(user.updated_at).toLocaleString() : '—'}
                      </td>
                      <td className="px-4 py-3 text-right">
                        <div className="flex items-center justify-end gap-1">
                          {rotatingUser === user.username ? (
                            <div className="flex items-center gap-2">
                              <label className="flex items-center gap-1 text-xs text-gray-500">
                                <input
                                  type="checkbox"
                                  checked={rotateAutoGen}
                                  onChange={e => setRotateAutoGen(e.target.checked)}
                                  className="rounded border-gray-300 text-blue-600"
                                />
                                Auto
                              </label>
                              {!rotateAutoGen && (
                                <input
                                  type="text"
                                  value={rotatePassword}
                                  onChange={e => setRotatePassword(e.target.value)}
                                  placeholder="New password"
                                  className="w-32 px-2 py-1 border rounded text-xs font-mono"
                                />
                              )}
                              <button
                                onClick={() => handleRotate(user.username)}
                                disabled={actionLoading === `rotate-${user.username}`}
                                className="px-2 py-1 bg-blue-600 text-white rounded text-xs hover:bg-blue-700 disabled:opacity-50"
                              >
                                {actionLoading === `rotate-${user.username}` ? (
                                  <Loader2 size={12} className="animate-spin" />
                                ) : (
                                  'Rotate'
                                )}
                              </button>
                              <button
                                onClick={() => setRotatingUser(null)}
                                className="px-2 py-1 border rounded text-xs hover:bg-gray-50"
                              >
                                Cancel
                              </button>
                            </div>
                          ) : (
                            <>
                              <button
                                onClick={() => { setRotatingUser(user.username); setRotatedResult(null); }}
                                className="p-1.5 text-blue-600 hover:bg-blue-50 rounded"
                                title="Rotate password"
                              >
                                <RotateCw size={14} />
                              </button>
                              <button
                                onClick={() => handleDeleteUser(user.username)}
                                disabled={actionLoading === user.username}
                                className="p-1.5 text-red-600 hover:bg-red-50 rounded"
                                title="Delete user"
                              >
                                {actionLoading === user.username ? (
                                  <Loader2 size={14} className="animate-spin" />
                                ) : (
                                  <Trash2 size={14} />
                                )}
                              </button>
                            </>
                          )}
                        </div>
                      </td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
          )}
        </div>
      )}

      {/* ══════════ ACLS TAB ══════════ */}
      {activeTab === 'acls' && (
        <div>
          {/* Error banner */}
          {aclsError && (
            <div className="flex items-center gap-2 bg-red-50 border border-red-200 rounded-lg px-4 py-3 mb-4 text-sm text-red-700">
              <AlertCircle size={16} />
              <span>{aclsError}</span>
              <button onClick={fetchAcls} className="ml-auto text-xs underline">Retry</button>
            </div>
          )}

          {/* Actions bar */}
          <div className="flex items-center gap-2 mb-4">
            <button
              onClick={() => setShowCreateAcl(true)}
              className="flex items-center gap-1.5 px-3 py-2 bg-blue-600 text-white rounded-lg text-sm hover:bg-blue-700"
            >
              <Plus size={14} /> Create ACL
            </button>
            <button
              onClick={fetchAcls}
              disabled={aclsLoading}
              className="flex items-center gap-1.5 px-3 py-2 border border-gray-300 rounded-lg text-sm hover:bg-gray-50"
            >
              <RefreshCw size={14} className={aclsLoading ? 'animate-spin' : ''} /> Refresh
            </button>
            <div className="ml-auto flex items-center gap-2">
              <div className="relative">
                <Search size={14} className="absolute left-2.5 top-2.5 text-gray-400" />
                <input
                  type="text"
                  value={aclFilterPrincipal}
                  onChange={e => setAclFilterPrincipal(e.target.value)}
                  placeholder="Filter principal..."
                  className="pl-8 pr-3 py-2 border rounded-lg text-sm w-44"
                />
              </div>
              <div className="relative">
                <Filter size={14} className="absolute left-2.5 top-2.5 text-gray-400" />
                <input
                  type="text"
                  value={aclFilterResource}
                  onChange={e => setAclFilterResource(e.target.value)}
                  placeholder="Filter resource..."
                  className="pl-8 pr-3 py-2 border rounded-lg text-sm w-44"
                />
              </div>
            </div>
          </div>

          {/* Create ACL form */}
          {showCreateAcl && (
            <div className="bg-blue-50 border border-blue-200 rounded-xl p-4 mb-4">
              <h4 className="text-sm font-medium text-blue-900 mb-3">Create ACL</h4>
              <div className="grid grid-cols-3 gap-3">
                <div>
                  <label className="text-xs text-gray-600 mb-1 block">Principal</label>
                  <input
                    type="text"
                    value={aclPrincipal}
                    onChange={e => setAclPrincipal(e.target.value)}
                    placeholder="User:myuser"
                    className="w-full px-3 py-2 border rounded-lg text-sm focus:ring-2 focus:ring-blue-500"
                  />
                </div>
                <div>
                  <label className="text-xs text-gray-600 mb-1 block">Resource Type</label>
                  <select
                    value={aclResourceType}
                    onChange={e => setAclResourceType(e.target.value)}
                    className="w-full px-3 py-2 border rounded-lg text-sm focus:ring-2 focus:ring-blue-500"
                  >
                    {RESOURCE_TYPES.map(rt => (
                      <option key={rt} value={rt}>{rt}</option>
                    ))}
                  </select>
                </div>
                <div>
                  <label className="text-xs text-gray-600 mb-1 block">Resource Name</label>
                  <input
                    type="text"
                    value={aclResourceName}
                    onChange={e => setAclResourceName(e.target.value)}
                    placeholder={aclResourceType === 'cluster' ? 'kafka-cluster' : 'my-topic'}
                    disabled={aclResourceType === 'cluster'}
                    className="w-full px-3 py-2 border rounded-lg text-sm focus:ring-2 focus:ring-blue-500 disabled:bg-gray-100"
                  />
                </div>
              </div>
              <div className="grid grid-cols-3 gap-3 mt-3">
                <div>
                  <label className="text-xs text-gray-600 mb-1 block">Pattern Type</label>
                  <select
                    value={aclPatternType}
                    onChange={e => setAclPatternType(e.target.value)}
                    className="w-full px-3 py-2 border rounded-lg text-sm focus:ring-2 focus:ring-blue-500"
                  >
                    <option value="literal">Literal</option>
                    <option value="prefixed">Prefixed</option>
                  </select>
                </div>
                <div>
                  <label className="text-xs text-gray-600 mb-1 block">Permission</label>
                  <select
                    value={aclPermission}
                    onChange={e => setAclPermission(e.target.value)}
                    className="w-full px-3 py-2 border rounded-lg text-sm focus:ring-2 focus:ring-blue-500"
                  >
                    <option value="Allow">Allow</option>
                    <option value="Deny">Deny</option>
                  </select>
                </div>
                <div>
                  <label className="text-xs text-gray-600 mb-1 block">Host</label>
                  <input
                    type="text"
                    value={aclHost}
                    onChange={e => setAclHost(e.target.value)}
                    placeholder="*"
                    className="w-full px-3 py-2 border rounded-lg text-sm focus:ring-2 focus:ring-blue-500"
                  />
                </div>
              </div>
              <div className="mt-3">
                <label className="text-xs text-gray-600 mb-1.5 block">Operations</label>
                <div className="flex flex-wrap gap-2">
                  {OPERATIONS.map(op => (
                    <label key={op} className="flex items-center gap-1.5 text-sm">
                      <input
                        type="checkbox"
                        checked={aclOperations.includes(op)}
                        onChange={() => toggleOperation(op)}
                        className="rounded border-gray-300 text-blue-600"
                      />
                      {op}
                    </label>
                  ))}
                </div>
              </div>
              <div className="flex gap-2 mt-3">
                <button
                  onClick={handleCreateAcl}
                  disabled={aclCreating || !aclPrincipal.trim() || aclOperations.length === 0 || (aclResourceType !== 'cluster' && !aclResourceName.trim())}
                  className="flex items-center gap-1.5 px-4 py-2 bg-blue-600 text-white rounded-lg text-sm hover:bg-blue-700 disabled:opacity-50"
                >
                  {aclCreating ? <Loader2 size={14} className="animate-spin" /> : <Plus size={14} />}
                  Create ACL
                </button>
                <button
                  onClick={() => setShowCreateAcl(false)}
                  className="px-4 py-2 border border-gray-300 rounded-lg text-sm hover:bg-gray-50"
                >
                  Cancel
                </button>
              </div>
            </div>
          )}

          {/* ACLs table */}
          {aclsLoading && !acls.length ? (
            <div className="flex items-center justify-center gap-2 py-8 text-gray-400 text-sm">
              <Loader2 size={16} className="animate-spin" /> Loading ACLs...
            </div>
          ) : filteredAcls.length === 0 ? (
            <div className="text-center py-12 text-gray-400 text-sm">
              <Lock size={32} className="mx-auto mb-2 opacity-50" />
              {acls.length === 0 ? 'No ACLs configured.' : 'No ACLs match the filter.'}
            </div>
          ) : (
            <div className="overflow-x-auto">
              <table className="w-full text-sm">
                <thead>
                  <tr className="bg-gray-50 text-left text-xs text-gray-500 uppercase">
                    <th className="px-4 py-3">Principal</th>
                    <th className="px-4 py-3">Resource</th>
                    <th className="px-4 py-3">Name</th>
                    <th className="px-4 py-3">Pattern</th>
                    <th className="px-4 py-3">Operation</th>
                    <th className="px-4 py-3">Permission</th>
                    <th className="px-4 py-3">Host</th>
                    <th className="px-4 py-3 text-right">Actions</th>
                  </tr>
                </thead>
                <tbody className="divide-y divide-gray-100">
                  {filteredAcls.map((acl, idx) => (
                    <tr key={`${acl.principal}-${acl.resource_name}-${acl.operation}-${idx}`} className="hover:bg-gray-50">
                      <td className="px-4 py-3 font-mono text-xs">{acl.principal}</td>
                      <td className="px-4 py-3">
                        <span className="px-2 py-0.5 bg-gray-100 text-gray-700 rounded text-xs">
                          {acl.resource_type}
                        </span>
                      </td>
                      <td className="px-4 py-3 font-mono text-xs">{acl.resource_name}</td>
                      <td className="px-4 py-3 text-xs text-gray-500">{acl.pattern_type}</td>
                      <td className="px-4 py-3">
                        <span className="px-2 py-0.5 bg-blue-100 text-blue-800 rounded text-xs">
                          {acl.operation}
                        </span>
                      </td>
                      <td className="px-4 py-3">
                        <span className={`px-2 py-0.5 rounded text-xs ${
                          acl.permission_type === 'Allow'
                            ? 'bg-green-100 text-green-800'
                            : 'bg-red-100 text-red-800'
                        }`}>
                          {acl.permission_type}
                        </span>
                      </td>
                      <td className="px-4 py-3 text-xs text-gray-500">{acl.host}</td>
                      <td className="px-4 py-3 text-right">
                        <button
                          onClick={() => handleDeleteAcl(acl)}
                          disabled={actionLoading === `acl-${acl.principal}-${acl.operation}-${acl.resource_name}`}
                          className="p-1.5 text-red-600 hover:bg-red-50 rounded"
                          title="Delete ACL"
                        >
                          {actionLoading === `acl-${acl.principal}-${acl.operation}-${acl.resource_name}` ? (
                            <Loader2 size={14} className="animate-spin" />
                          ) : (
                            <Trash2 size={14} />
                          )}
                        </button>
                      </td>
                    </tr>
                  ))}
                </tbody>
              </table>
              <div className="text-xs text-gray-400 px-4 py-2">
                Showing {filteredAcls.length} of {acls.length} ACL entries
              </div>
            </div>
          )}
        </div>
      )}

      {/* ══════════ AUDIT LOG TAB ══════════ */}
      {activeTab === 'audit' && (
        <div>
          <div className="flex items-center gap-2 mb-4">
            <button
              onClick={fetchAuditLog}
              disabled={auditLoading}
              className="flex items-center gap-1.5 px-3 py-2 border border-gray-300 rounded-lg text-sm hover:bg-gray-50"
            >
              <RefreshCw size={14} className={auditLoading ? 'animate-spin' : ''} /> Refresh
            </button>
            <select
              value={auditFilter}
              onChange={e => setAuditFilter(e.target.value)}
              className="px-3 py-2 border rounded-lg text-sm"
            >
              <option value="">All Actions</option>
              <option value="user_created">User Created</option>
              <option value="user_deleted">User Deleted</option>
              <option value="user_password_rotated">Password Rotated</option>
              <option value="acl_created">ACL Created</option>
              <option value="acl_deleted">ACL Deleted</option>
            </select>
          </div>

          {auditLoading && !auditLogs.length ? (
            <div className="flex items-center justify-center gap-2 py-8 text-gray-400 text-sm">
              <Loader2 size={16} className="animate-spin" /> Loading audit log...
            </div>
          ) : auditLogs.length === 0 ? (
            <div className="text-center py-12 text-gray-400 text-sm">
              <Clock size={32} className="mx-auto mb-2 opacity-50" />
              No audit log entries yet.
            </div>
          ) : (
            <div className="overflow-x-auto">
              <table className="w-full text-sm">
                <thead>
                  <tr className="bg-gray-50 text-left text-xs text-gray-500 uppercase">
                    <th className="px-4 py-3">Time</th>
                    <th className="px-4 py-3">Action</th>
                    <th className="px-4 py-3">Type</th>
                    <th className="px-4 py-3">Resource</th>
                    <th className="px-4 py-3">Details</th>
                  </tr>
                </thead>
                <tbody className="divide-y divide-gray-100">
                  {auditLogs.map(log => (
                    <tr key={log.id} className="hover:bg-gray-50">
                      <td className="px-4 py-3 text-xs text-gray-500 whitespace-nowrap">
                        {new Date(log.created_at).toLocaleString()}
                      </td>
                      <td className="px-4 py-3">
                        <span className={`px-2 py-0.5 rounded text-xs font-medium ${ACTION_COLORS[log.action] || 'bg-gray-100 text-gray-800'}`}>
                          {log.action.replace(/_/g, ' ')}
                        </span>
                      </td>
                      <td className="px-4 py-3 text-xs text-gray-500">{log.resource_type}</td>
                      <td className="px-4 py-3 font-mono text-xs">{log.resource_name}</td>
                      <td className="px-4 py-3">
                        {log.details ? (
                          <button
                            onClick={() => setExpandedLog(expandedLog === log.id ? null : log.id)}
                            className="text-blue-600 text-xs hover:underline flex items-center gap-1"
                          >
                            {expandedLog === log.id ? <ChevronUp size={12} /> : <ChevronDown size={12} />}
                            {expandedLog === log.id ? 'Hide' : 'View'}
                          </button>
                        ) : (
                          <span className="text-gray-300 text-xs">—</span>
                        )}
                      </td>
                    </tr>
                  ))}
                  {/* Expanded detail rows */}
                  {auditLogs.map(log =>
                    expandedLog === log.id && log.details ? (
                      <tr key={`${log.id}-detail`}>
                        <td colSpan={5} className="px-4 py-3 bg-gray-50">
                          <pre className="text-xs font-mono text-gray-600 whitespace-pre-wrap">
                            {(() => {
                              try {
                                return JSON.stringify(JSON.parse(log.details!), null, 2);
                              } catch {
                                return log.details;
                              }
                            })()}
                          </pre>
                        </td>
                      </tr>
                    ) : null,
                  )}
                </tbody>
              </table>
            </div>
          )}
        </div>
      )}
    </div>
  );
}
