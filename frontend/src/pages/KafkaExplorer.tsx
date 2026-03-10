import { useState, useEffect, useRef, useCallback } from 'react';
import {
  Globe, Play, Square, RotateCw, Trash2, Save, RefreshCw,
  ExternalLink, CheckCircle, XCircle, Circle, Rocket,
  ChevronDown, ChevronUp, FileCode, AlertTriangle,
} from 'lucide-react';
import axios from 'axios';
import { getAccessToken, isAdmin } from '../lib/auth';
import type { Cluster } from '../types';

// ── Authenticated Axios Instance ──────────────────────
const authApi = axios.create({ baseURL: '/api' });
authApi.interceptors.request.use((config) => {
  const token = getAccessToken();
  if (token) config.headers.Authorization = `Bearer ${token}`;
  return config;
});

// ── Types ─────────────────────────────────────────────
interface KafkaUIStatus {
  cluster_id: string;
  is_deployed: boolean;
  is_running: boolean;
  port: number;
  deploy_host_id: string | null;
  deploy_host_ip: string | null;
  url: string | null;
}

interface DeployTask {
  task_id: string;
  status: string;
  logs: string[];
}

// ── API Functions ─────────────────────────────────────
const getClusters = () => authApi.get<Cluster[]>('/clusters').then(r => r.data);
const getUIStatus = (clusterId: string) =>
  authApi.get<KafkaUIStatus>(`/kafka-ui/clusters/${clusterId}/status`).then(r => r.data);
const getUIConfig = (clusterId: string) =>
  authApi.get<{ config_yaml: string; is_deployed: boolean }>(`/kafka-ui/clusters/${clusterId}/config`).then(r => r.data);
const deployUI = (clusterId: string, port: number) =>
  authApi.post<{ task_id: string }>(`/kafka-ui/clusters/${clusterId}/deploy`, { port }).then(r => r.data);
const getDeployTask = (taskId: string) =>
  authApi.get<DeployTask>(`/kafka-ui/tasks/${taskId}`).then(r => r.data);
const updateUIConfig = (clusterId: string, configYaml: string) =>
  authApi.put(`/kafka-ui/clusters/${clusterId}/config`, { config_yaml: configYaml }).then(r => r.data);
const restartUI = (clusterId: string) =>
  authApi.post(`/kafka-ui/clusters/${clusterId}/restart`).then(r => r.data);
const stopUI = (clusterId: string) =>
  authApi.post(`/kafka-ui/clusters/${clusterId}/stop`).then(r => r.data);
const undeployUI = (clusterId: string) =>
  authApi.delete(`/kafka-ui/clusters/${clusterId}`).then(r => r.data);

// ── Status Badge ──────────────────────────────────────
function StatusBadge({ isDeployed, isRunning }: { isDeployed: boolean; isRunning: boolean }) {
  if (!isDeployed) {
    return (
      <span className="inline-flex items-center gap-1.5 px-2.5 py-1 rounded-full text-xs font-medium bg-gray-100 text-gray-600">
        <Circle size={8} className="fill-gray-400 text-gray-400" />
        Not Deployed
      </span>
    );
  }
  if (isRunning) {
    return (
      <span className="inline-flex items-center gap-1.5 px-2.5 py-1 rounded-full text-xs font-medium bg-green-100 text-green-700">
        <CheckCircle size={12} />
        Running
      </span>
    );
  }
  return (
    <span className="inline-flex items-center gap-1.5 px-2.5 py-1 rounded-full text-xs font-medium bg-red-100 text-red-700">
      <XCircle size={12} />
      Stopped
    </span>
  );
}

// ── Cluster Card Component ────────────────────────────
function ClusterCard({
  cluster,
  onRefreshAll,
}: {
  cluster: Cluster;
  onRefreshAll: () => void;
}) {
  const admin = isAdmin();
  const [status, setStatus] = useState<KafkaUIStatus | null>(null);
  const [loading, setLoading] = useState(true);
  const [expanded, setExpanded] = useState(false);
  const [port, setPort] = useState(8080);
  const [deploying, setDeploying] = useState(false);
  const [deployTaskId, setDeployTaskId] = useState<string | null>(null);
  const [deployLogs, setDeployLogs] = useState<string[]>([]);
  const [showConfig, setShowConfig] = useState(false);
  const [configYaml, setConfigYaml] = useState('');
  const [configDirty, setConfigDirty] = useState(false);
  const [saving, setSaving] = useState(false);
  const [actionLoading, setActionLoading] = useState<string | null>(null);
  const [error, setError] = useState('');
  const [yamlError, setYamlError] = useState('');
  const logsEndRef = useRef<HTMLDivElement>(null);

  const fetchStatus = useCallback(async () => {
    try {
      const data = await getUIStatus(cluster.id);
      setStatus(data);
      setPort(data.port || 8080);
    } catch {
      setStatus({
        cluster_id: cluster.id,
        is_deployed: false,
        is_running: false,
        port: 8080,
        deploy_host_id: null,
        deploy_host_ip: null,
        url: null,
      });
    } finally {
      setLoading(false);
    }
  }, [cluster.id]);

  useEffect(() => {
    fetchStatus();
  }, [fetchStatus]);

  // Poll deploy task
  useEffect(() => {
    if (!deployTaskId) return;
    const interval = setInterval(async () => {
      try {
        const task = await getDeployTask(deployTaskId);
        setDeployLogs(task.logs);
        if (task.status !== 'running') {
          clearInterval(interval);
          setDeploying(false);
          setDeployTaskId(null);
          fetchStatus();
          if (task.status === 'error') {
            setError('Deployment failed. Check the logs above for details.');
          }
        }
      } catch {
        clearInterval(interval);
        setDeploying(false);
      }
    }, 1500);
    return () => clearInterval(interval);
  }, [deployTaskId, fetchStatus]);

  // Auto-scroll logs
  useEffect(() => {
    logsEndRef.current?.scrollIntoView({ behavior: 'smooth' });
  }, [deployLogs]);

  const handleDeploy = async () => {
    setDeploying(true);
    setError('');
    setDeployLogs([]);
    setExpanded(true);
    try {
      const result = await deployUI(cluster.id, port);
      setDeployTaskId(result.task_id);
    } catch (err: unknown) {
      const msg = (err as { response?: { data?: { detail?: string } } })?.response?.data?.detail || 'Deploy request failed';
      setError(msg);
      setDeploying(false);
    }
  };

  const handleAction = async (action: 'restart' | 'stop' | 'undeploy') => {
    setActionLoading(action);
    setError('');
    try {
      if (action === 'restart') await restartUI(cluster.id);
      else if (action === 'stop') await stopUI(cluster.id);
      else if (action === 'undeploy') await undeployUI(cluster.id);
      await fetchStatus();
      onRefreshAll();
    } catch (err: unknown) {
      const msg = (err as { response?: { data?: { detail?: string } } })?.response?.data?.detail || `${action} failed`;
      setError(msg);
    } finally {
      setActionLoading(null);
    }
  };

  const handleLoadConfig = async () => {
    setShowConfig(!showConfig);
    if (!showConfig) {
      try {
        const data = await getUIConfig(cluster.id);
        setConfigYaml(data.config_yaml);
        setConfigDirty(false);
        setYamlError('');
      } catch {
        setError('Failed to load configuration');
      }
    }
  };

  const validateYaml = (text: string): boolean => {
    // Basic YAML validation: check for obvious issues
    const lines = text.split('\n');
    for (let i = 0; i < lines.length; i++) {
      const line = lines[i];
      // Check for tabs (YAML uses spaces only)
      if (line.includes('\t')) {
        setYamlError(`Line ${i + 1}: Tabs are not allowed in YAML, use spaces`);
        return false;
      }
    }
    // Check that it has some content
    if (text.trim().length === 0) {
      setYamlError('Config cannot be empty');
      return false;
    }
    setYamlError('');
    return true;
  };

  const handleSaveConfig = async () => {
    if (!validateYaml(configYaml)) return;
    setSaving(true);
    setError('');
    try {
      await updateUIConfig(cluster.id, configYaml);
      setConfigDirty(false);
      await fetchStatus();
    } catch (err: unknown) {
      const msg = (err as { response?: { data?: { detail?: string } } })?.response?.data?.detail || 'Failed to save config';
      setError(msg);
    } finally {
      setSaving(false);
    }
  };

  if (loading) {
    return (
      <div className="bg-white border border-gray-200 rounded-xl p-6 shadow-sm">
        <div className="flex items-center gap-3">
          <div className="w-5 h-5 border-2 border-blue-500/30 border-t-blue-500 rounded-full animate-spin" />
          <span className="text-gray-500 text-sm">Loading {cluster.name}...</span>
        </div>
      </div>
    );
  }

  const isDeployed = status?.is_deployed || false;
  const isRunning = status?.is_running || false;

  return (
    <div className="bg-white border border-gray-200 rounded-xl shadow-sm overflow-hidden">
      {/* Header */}
      <div
        className="flex items-center justify-between p-5 cursor-pointer hover:bg-gray-50 transition-colors"
        onClick={() => setExpanded(!expanded)}
      >
        <div className="flex items-center gap-4">
          <div className={`w-10 h-10 rounded-lg flex items-center justify-center ${
            isRunning ? 'bg-green-100' : isDeployed ? 'bg-red-100' : 'bg-gray-100'
          }`}>
            <Globe size={20} className={
              isRunning ? 'text-green-600' : isDeployed ? 'text-red-500' : 'text-gray-400'
            } />
          </div>
          <div>
            <h3 className="font-semibold text-gray-900">{cluster.name}</h3>
            <p className="text-xs text-gray-500 mt-0.5">
              Kafka {cluster.kafka_version} &middot; {cluster.mode}
              {status?.deploy_host_ip && (
                <> &middot; Host: {status.deploy_host_ip}</>
              )}
              {status?.port && isDeployed && (
                <> &middot; Port: {status.port}</>
              )}
            </p>
          </div>
        </div>
        <div className="flex items-center gap-3">
          <StatusBadge isDeployed={isDeployed} isRunning={isRunning} />
          {expanded ? <ChevronUp size={18} className="text-gray-400" /> : <ChevronDown size={18} className="text-gray-400" />}
        </div>
      </div>

      {/* Expanded content */}
      {expanded && (
        <div className="border-t border-gray-100 p-5 space-y-4">
          {error && (
            <div className="flex items-start gap-2 p-3 bg-red-50 border border-red-200 rounded-lg text-red-700 text-sm">
              <AlertTriangle size={16} className="mt-0.5 flex-shrink-0" />
              <span>{error}</span>
            </div>
          )}

          {/* Not deployed — deploy form */}
          {!isDeployed && !deploying && admin && (
            <div className="bg-blue-50 border border-blue-200 rounded-lg p-4">
              <h4 className="font-medium text-blue-900 mb-2">Deploy Data Explorer</h4>
              <p className="text-sm text-blue-700 mb-3">
                Deploy a Data Explorer instance to this cluster's first broker host.
                This enables a web UI for browsing topics, consumer groups, and cluster configuration.
              </p>
              <div className="flex items-end gap-3">
                <div>
                  <label className="block text-xs font-medium text-blue-800 mb-1">Port</label>
                  <input
                    type="number"
                    value={port}
                    onChange={e => setPort(Number(e.target.value))}
                    min={1024}
                    max={65535}
                    className="w-28 px-3 py-2 border border-blue-300 rounded-lg text-sm bg-white focus:outline-none focus:ring-2 focus:ring-blue-500"
                  />
                </div>
                <button
                  onClick={handleDeploy}
                  className="flex items-center gap-2 px-4 py-2 bg-blue-600 hover:bg-blue-700 text-white rounded-lg text-sm font-medium transition-colors"
                >
                  <Rocket size={16} />
                  Deploy
                </button>
              </div>
            </div>
          )}

          {/* Deploying in progress */}
          {deploying && (
            <div className="space-y-3">
              <div className="flex items-center gap-2 text-sm text-blue-700">
                <div className="w-4 h-4 border-2 border-blue-500/30 border-t-blue-500 rounded-full animate-spin" />
                Deploying Data Explorer...
              </div>
            </div>
          )}

          {/* Deploy logs */}
          {deployLogs.length > 0 && (
            <div className="bg-gray-900 rounded-lg overflow-hidden">
              <div className="flex items-center justify-between px-4 py-2 bg-gray-800">
                <span className="text-xs text-gray-400 font-medium">Deployment Logs</span>
                <span className={`text-xs px-2 py-0.5 rounded-full ${
                  deploying ? 'bg-blue-900 text-blue-300' : 'bg-green-900 text-green-300'
                }`}>
                  {deploying ? 'Running' : 'Complete'}
                </span>
              </div>
              <div className="p-4 max-h-72 overflow-y-auto">
                <pre className="text-xs text-gray-300 font-mono whitespace-pre-wrap leading-relaxed">
                  {deployLogs.join('\n')}
                </pre>
                <div ref={logsEndRef} />
              </div>
            </div>
          )}

          {/* Deployed — action buttons */}
          {isDeployed && !deploying && (
            <div className="flex flex-wrap items-center gap-2">
              {isRunning && status?.url && (
                <a
                  href={status.url}
                  target="_blank"
                  rel="noopener noreferrer"
                  className="flex items-center gap-2 px-4 py-2 bg-green-600 hover:bg-green-700 text-white rounded-lg text-sm font-medium transition-colors"
                >
                  <ExternalLink size={14} />
                  Open Data Explorer
                </a>
              )}
              {admin && (
                <>
                  <button
                    onClick={() => handleAction('restart')}
                    disabled={actionLoading === 'restart'}
                    className="flex items-center gap-2 px-3 py-2 bg-blue-600 hover:bg-blue-700 disabled:bg-blue-400 text-white rounded-lg text-sm font-medium transition-colors"
                  >
                    {actionLoading === 'restart' ? (
                      <div className="w-3.5 h-3.5 border-2 border-white/30 border-t-white rounded-full animate-spin" />
                    ) : (
                      <RotateCw size={14} />
                    )}
                    Restart
                  </button>
                  {isRunning ? (
                    <button
                      onClick={() => handleAction('stop')}
                      disabled={actionLoading === 'stop'}
                      className="flex items-center gap-2 px-3 py-2 bg-amber-600 hover:bg-amber-700 disabled:bg-amber-400 text-white rounded-lg text-sm font-medium transition-colors"
                    >
                      {actionLoading === 'stop' ? (
                        <div className="w-3.5 h-3.5 border-2 border-white/30 border-t-white rounded-full animate-spin" />
                      ) : (
                        <Square size={14} />
                      )}
                      Stop
                    </button>
                  ) : (
                    <button
                      onClick={() => handleAction('restart')}
                      disabled={actionLoading === 'restart'}
                      className="flex items-center gap-2 px-3 py-2 bg-green-600 hover:bg-green-700 disabled:bg-green-400 text-white rounded-lg text-sm font-medium transition-colors"
                    >
                      {actionLoading === 'restart' ? (
                        <div className="w-3.5 h-3.5 border-2 border-white/30 border-t-white rounded-full animate-spin" />
                      ) : (
                        <Play size={14} />
                      )}
                      Start
                    </button>
                  )}
                  <button
                    onClick={handleLoadConfig}
                    className={`flex items-center gap-2 px-3 py-2 border rounded-lg text-sm font-medium transition-colors ${
                      showConfig
                        ? 'border-indigo-300 bg-indigo-50 text-indigo-700 hover:bg-indigo-100'
                        : 'border-gray-300 text-gray-700 hover:bg-gray-50'
                    }`}
                  >
                    <FileCode size={14} />
                    Config
                  </button>
                  <button
                    onClick={() => {
                      if (window.confirm('Are you sure you want to undeploy the Data Explorer? This will stop the service and remove all files from the host.')) {
                        handleAction('undeploy');
                      }
                    }}
                    disabled={actionLoading === 'undeploy'}
                    className="flex items-center gap-2 px-3 py-2 bg-red-600 hover:bg-red-700 disabled:bg-red-400 text-white rounded-lg text-sm font-medium transition-colors"
                  >
                    {actionLoading === 'undeploy' ? (
                      <div className="w-3.5 h-3.5 border-2 border-white/30 border-t-white rounded-full animate-spin" />
                    ) : (
                      <Trash2 size={14} />
                    )}
                    Undeploy
                  </button>
                </>
              )}
            </div>
          )}

          {/* YAML Config Editor */}
          {showConfig && isDeployed && (
            <div className="space-y-3">
              <div className="flex items-center justify-between">
                <h4 className="text-sm font-medium text-gray-700">Configuration (YAML)</h4>
                <div className="flex items-center gap-2">
                  {configDirty && (
                    <span className="text-xs text-amber-600 font-medium">Unsaved changes</span>
                  )}
                  <button
                    onClick={handleSaveConfig}
                    disabled={saving || !configDirty}
                    className="flex items-center gap-1.5 px-3 py-1.5 bg-indigo-600 hover:bg-indigo-700 disabled:bg-gray-300 disabled:text-gray-500 text-white rounded-lg text-xs font-medium transition-colors"
                  >
                    {saving ? (
                      <div className="w-3 h-3 border-2 border-white/30 border-t-white rounded-full animate-spin" />
                    ) : (
                      <Save size={12} />
                    )}
                    Save & Restart
                  </button>
                </div>
              </div>
              {yamlError && (
                <div className="p-2 bg-red-50 border border-red-200 rounded text-red-700 text-xs">
                  {yamlError}
                </div>
              )}
              <textarea
                value={configYaml}
                onChange={e => {
                  setConfigYaml(e.target.value);
                  setConfigDirty(true);
                  validateYaml(e.target.value);
                }}
                spellCheck={false}
                className="w-full h-64 p-4 font-mono text-sm bg-gray-900 text-gray-100 border border-gray-700 rounded-lg resize-y focus:outline-none focus:ring-2 focus:ring-indigo-500 leading-relaxed"
                placeholder="# kafbat-ui configuration YAML..."
              />
            </div>
          )}

          {/* Embedded UI iframe when running */}
          {isRunning && status?.url && isDeployed && (
            <div className="border border-gray-200 rounded-lg overflow-hidden">
              <div className="flex items-center justify-between px-4 py-2 bg-gray-50 border-b border-gray-200">
                <span className="text-xs font-medium text-gray-600">Data Explorer Preview</span>
                <a
                  href={status.url}
                  target="_blank"
                  rel="noopener noreferrer"
                  className="flex items-center gap-1 text-xs text-blue-600 hover:text-blue-700"
                >
                  Open in new tab <ExternalLink size={10} />
                </a>
              </div>
              <iframe
                src={status.url}
                className="w-full h-[500px]"
                title={`Data Explorer - ${cluster.name}`}
              />
            </div>
          )}
        </div>
      )}
    </div>
  );
}

// ── Main Page ─────────────────────────────────────────
export default function KafkaExplorer() {
  const [clusters, setClusters] = useState<Cluster[]>([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState('');

  const fetchClusters = async () => {
    try {
      const data = await getClusters();
      // Show all clusters, not just running ones — users may want to deploy before the cluster is running
      setClusters(data);
    } catch {
      setError('Failed to load clusters');
    } finally {
      setLoading(false);
    }
  };

  useEffect(() => {
    fetchClusters();
  }, []);

  if (loading) {
    return (
      <div className="flex items-center justify-center h-64">
        <div className="w-8 h-8 border-4 border-blue-500/30 border-t-blue-500 rounded-full animate-spin" />
      </div>
    );
  }

  return (
    <div className="space-y-6">
      {/* Page header */}
      <div className="flex items-center justify-between">
        <div>
          <h1 className="text-2xl font-bold text-gray-900 flex items-center gap-2">
            <Globe size={24} />
            Data Explorer
          </h1>
          <p className="text-gray-500 mt-1">
            Deploy and manage web-based Kafka data exploration interfaces per cluster
          </p>
        </div>
        <button
          onClick={() => { setLoading(true); fetchClusters(); }}
          className="flex items-center gap-2 px-3 py-2 text-gray-600 hover:text-gray-900 border border-gray-300 rounded-lg hover:bg-gray-50 transition-colors"
        >
          <RefreshCw size={16} />
          Refresh
        </button>
      </div>

      {error && (
        <div className="p-3 bg-red-50 border border-red-200 rounded-lg text-red-700 text-sm">
          {error}
        </div>
      )}

      {/* Cluster cards */}
      {clusters.length > 0 ? (
        <div className="space-y-4">
          {clusters.map(cluster => (
            <ClusterCard
              key={cluster.id}
              cluster={cluster}
              onRefreshAll={fetchClusters}
            />
          ))}
        </div>
      ) : (
        <div className="bg-gray-50 border border-gray-200 rounded-xl p-12 text-center">
          <Globe size={40} className="mx-auto text-gray-400 mb-4" />
          <h3 className="text-lg font-semibold text-gray-700">No Clusters Found</h3>
          <p className="text-sm text-gray-500 mt-2 max-w-md mx-auto">
            Create a Kafka cluster first, then come back here to deploy a Data Explorer instance
            for browsing topics, consumer groups, and configurations.
          </p>
        </div>
      )}
    </div>
  );
}
