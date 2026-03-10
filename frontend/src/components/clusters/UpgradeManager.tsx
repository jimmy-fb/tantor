import { useState, useEffect, useRef, useCallback } from 'react';
import {
  ArrowUpCircle, RefreshCw, Loader2, CheckCircle, XCircle,
  AlertTriangle, Shield, ChevronDown, ChevronUp, Play,
  Clock, FileText,
} from 'lucide-react';
import axios from 'axios';
import { getAccessToken } from '../../lib/auth';

const authApi = axios.create({ baseURL: '/api' });
authApi.interceptors.request.use((config) => {
  const token = getAccessToken();
  if (token) config.headers.Authorization = `Bearer ${token}`;
  return config;
});

interface Props {
  clusterId: string;
  currentVersion: string;
}

interface AvailableVersion {
  version: string;
  scala_version: string;
  filename: string;
  size_mb: number;
}

interface AvailableUpgradesResponse {
  cluster_id: string;
  cluster_name: string;
  current_version: string;
  available_upgrades: AvailableVersion[];
}

interface CheckDetail {
  check: string;
  passed: boolean;
  message: string;
  warning?: boolean;
  details?: Array<{
    node_id: number;
    host: string;
    hostname?: string;
    status: string;
    healthy: boolean;
    error?: string;
  }>;
  under_replicated_partitions?: number;
}

interface PreCheckResponse {
  cluster_id: string;
  cluster_name: string;
  current_version: string;
  target_version: string;
  ready: boolean;
  checks: CheckDetail[];
}

interface UpgradeProgress {
  current: number;
  total: number;
  phase: string;
}

interface LogEntry {
  timestamp: string;
  level: string;
  message: string;
}

interface UpgradeTask {
  status: string;
  logs: LogEntry[];
  progress: UpgradeProgress;
  started_at: string | null;
  completed_at: string | null;
  error: string | null;
}

const CHECK_LABELS: Record<string, string> = {
  version_comparison: 'Version Compatibility',
  binary_available: 'Binary Available',
  broker_health: 'Broker Health',
  isr_status: 'ISR Status',
  controller_status: 'Controller Status',
};

export default function UpgradeManager({ clusterId, currentVersion }: Props) {
  const [loading, setLoading] = useState(false);
  const [available, setAvailable] = useState<AvailableUpgradesResponse | null>(null);
  const [selectedVersion, setSelectedVersion] = useState<string>('');
  const [preCheck, setPreCheck] = useState<PreCheckResponse | null>(null);
  const [preCheckLoading, setPreCheckLoading] = useState(false);
  const [preCheckError, setPreCheckError] = useState<string | null>(null);
  const [upgradeTaskId, setUpgradeTaskId] = useState<string | null>(null);
  const [upgradeTask, setUpgradeTask] = useState<UpgradeTask | null>(null);
  const [upgradeError, setUpgradeError] = useState<string | null>(null);
  const [showConfirm, setShowConfirm] = useState(false);
  const [showLogs, setShowLogs] = useState(false);
  const pollRef = useRef<ReturnType<typeof setInterval> | null>(null);
  const logEndRef = useRef<HTMLDivElement>(null);

  const fetchAvailable = useCallback(async () => {
    setLoading(true);
    try {
      const { data } = await authApi.get<AvailableUpgradesResponse>(
        `/upgrades/clusters/${clusterId}/available`
      );
      setAvailable(data);
      if (data.available_upgrades.length > 0 && !selectedVersion) {
        setSelectedVersion(data.available_upgrades[data.available_upgrades.length - 1].version);
      }
    } catch {
      setAvailable(null);
    } finally {
      setLoading(false);
    }
  }, [clusterId, selectedVersion]);

  useEffect(() => {
    fetchAvailable();
  }, [clusterId]);

  // Poll for upgrade task status
  useEffect(() => {
    if (!upgradeTaskId) return;

    const poll = async () => {
      try {
        const { data } = await authApi.get<UpgradeTask>(`/upgrades/tasks/${upgradeTaskId}`);
        setUpgradeTask(data);

        if (data.status === 'completed' || data.status === 'failed') {
          if (pollRef.current) {
            clearInterval(pollRef.current);
            pollRef.current = null;
          }
          if (data.status === 'completed') {
            fetchAvailable();
          }
        }
      } catch {
        // Keep polling on transient errors
      }
    };

    poll();
    pollRef.current = setInterval(poll, 2000);

    return () => {
      if (pollRef.current) {
        clearInterval(pollRef.current);
        pollRef.current = null;
      }
    };
  }, [upgradeTaskId]);

  // Auto-scroll logs
  useEffect(() => {
    if (showLogs && logEndRef.current) {
      logEndRef.current.scrollIntoView({ behavior: 'smooth' });
    }
  }, [upgradeTask?.logs?.length, showLogs]);

  const handlePreCheck = async () => {
    if (!selectedVersion) return;
    setPreCheckLoading(true);
    setPreCheckError(null);
    setPreCheck(null);
    try {
      const { data } = await authApi.post<PreCheckResponse>(
        `/upgrades/clusters/${clusterId}/pre-check`,
        { target_version: selectedVersion }
      );
      setPreCheck(data);
    } catch (err: unknown) {
      const msg = (err as { response?: { data?: { detail?: string } } })?.response?.data?.detail;
      setPreCheckError(msg || 'Pre-upgrade check failed');
    } finally {
      setPreCheckLoading(false);
    }
  };

  const handleStartUpgrade = async () => {
    if (!selectedVersion) return;
    setShowConfirm(false);
    setUpgradeError(null);
    setUpgradeTask(null);
    setShowLogs(true);
    try {
      const { data } = await authApi.post<{ task_id: string; status: string }>(
        `/upgrades/clusters/${clusterId}/upgrade`,
        { target_version: selectedVersion }
      );
      setUpgradeTaskId(data.task_id);
    } catch (err: unknown) {
      const msg = (err as { response?: { data?: { detail?: string } } })?.response?.data?.detail;
      setUpgradeError(msg || 'Failed to start upgrade');
    }
  };

  const isUpgrading = upgradeTask?.status === 'running';
  const isCompleted = upgradeTask?.status === 'completed';
  const isFailed = upgradeTask?.status === 'failed';
  const progress = upgradeTask?.progress;
  const progressPct = progress && progress.total > 0
    ? Math.round((progress.current / progress.total) * 100)
    : 0;

  return (
    <div className="space-y-6">
      {/* Current Version Banner */}
      <div className="flex items-center gap-3 bg-gray-50 border rounded-xl px-5 py-4">
        <ArrowUpCircle size={22} className="text-blue-600 shrink-0" />
        <div className="flex-1">
          <h3 className="text-sm font-semibold text-gray-800">Kafka Version Upgrade</h3>
          <p className="text-xs text-gray-500 mt-0.5">
            Current version: <span className="font-mono font-medium text-gray-700">{currentVersion}</span>
          </p>
        </div>
        <button
          onClick={fetchAvailable}
          disabled={loading || isUpgrading}
          className="flex items-center gap-1.5 px-3 py-1.5 text-xs border rounded-lg hover:bg-white disabled:opacity-50"
        >
          {loading ? <Loader2 size={13} className="animate-spin" /> : <RefreshCw size={13} />}
          Refresh
        </button>
      </div>

      {/* Version Selection */}
      {available && !isUpgrading && !isCompleted && (
        <div className="bg-white border rounded-xl p-5">
          <h4 className="text-sm font-medium text-gray-800 mb-3">Available Upgrades</h4>
          {available.available_upgrades.length === 0 ? (
            <div className="text-center py-6">
              <CheckCircle size={28} className="mx-auto text-green-400 mb-2" />
              <p className="text-sm text-gray-500">
                You are running the latest available version.
              </p>
              <p className="text-xs text-gray-400 mt-1">
                Upload newer Kafka binaries in the Version Management page to enable upgrades.
              </p>
            </div>
          ) : (
            <div className="space-y-4">
              <div className="grid gap-2">
                {available.available_upgrades.map((v) => (
                  <label
                    key={v.version}
                    className={`flex items-center gap-3 px-4 py-3 border rounded-lg cursor-pointer transition-colors ${
                      selectedVersion === v.version
                        ? 'border-blue-400 bg-blue-50 ring-1 ring-blue-200'
                        : 'hover:bg-gray-50'
                    }`}
                  >
                    <input
                      type="radio"
                      name="target_version"
                      value={v.version}
                      checked={selectedVersion === v.version}
                      onChange={() => {
                        setSelectedVersion(v.version);
                        setPreCheck(null);
                        setPreCheckError(null);
                      }}
                      className="text-blue-600 focus:ring-blue-500"
                    />
                    <div className="flex-1">
                      <span className="text-sm font-mono font-medium text-gray-800">
                        Kafka {v.version}
                      </span>
                      <span className="text-xs text-gray-400 ml-2">
                        (Scala {v.scala_version})
                      </span>
                    </div>
                    <span className="text-xs text-gray-400">{v.size_mb} MB</span>
                    <span className="text-xs text-gray-400 font-mono">{v.filename}</span>
                  </label>
                ))}
              </div>

              {/* Action Buttons */}
              <div className="flex items-center gap-3 pt-2">
                <button
                  onClick={handlePreCheck}
                  disabled={!selectedVersion || preCheckLoading}
                  className="flex items-center gap-2 px-4 py-2 text-sm border-2 border-blue-200 text-blue-700 rounded-lg hover:bg-blue-50 disabled:opacity-50"
                >
                  {preCheckLoading ? (
                    <Loader2 size={15} className="animate-spin" />
                  ) : (
                    <Shield size={15} />
                  )}
                  Run Pre-Check
                </button>

                <button
                  onClick={() => setShowConfirm(true)}
                  disabled={!selectedVersion || !preCheck?.ready}
                  className="flex items-center gap-2 px-4 py-2 text-sm bg-green-600 text-white rounded-lg hover:bg-green-700 disabled:opacity-50 disabled:cursor-not-allowed"
                >
                  <Play size={15} />
                  Start Upgrade
                </button>

                {!preCheck?.ready && selectedVersion && !preCheckLoading && (
                  <p className="text-xs text-gray-400">
                    Run pre-check first to enable upgrade
                  </p>
                )}
              </div>
            </div>
          )}
        </div>
      )}

      {/* Pre-Check Error */}
      {preCheckError && (
        <div className="flex items-start gap-2 bg-red-50 border border-red-200 rounded-xl px-4 py-3 text-sm text-red-700">
          <XCircle size={16} className="mt-0.5 shrink-0" />
          <span>{preCheckError}</span>
        </div>
      )}

      {/* Pre-Check Results */}
      {preCheck && !isUpgrading && (
        <div className="bg-white border rounded-xl overflow-hidden">
          <div className={`flex items-center gap-3 px-5 py-4 border-b ${
            preCheck.ready ? 'bg-green-50' : 'bg-red-50'
          }`}>
            {preCheck.ready ? (
              <CheckCircle size={20} className="text-green-600" />
            ) : (
              <XCircle size={20} className="text-red-600" />
            )}
            <div>
              <p className={`text-sm font-medium ${preCheck.ready ? 'text-green-800' : 'text-red-800'}`}>
                {preCheck.ready
                  ? 'Cluster is ready for upgrade'
                  : 'Cluster is not ready for upgrade'}
              </p>
              <p className="text-xs text-gray-500 mt-0.5">
                {preCheck.current_version} &rarr; {preCheck.target_version}
              </p>
            </div>
          </div>

          <div className="divide-y">
            {preCheck.checks.map((check, i) => (
              <div key={i} className="px-5 py-3">
                <div className="flex items-center gap-3">
                  {check.passed ? (
                    check.warning ? (
                      <AlertTriangle size={16} className="text-yellow-500 shrink-0" />
                    ) : (
                      <CheckCircle size={16} className="text-green-500 shrink-0" />
                    )
                  ) : (
                    <XCircle size={16} className="text-red-500 shrink-0" />
                  )}
                  <div className="flex-1 min-w-0">
                    <span className="text-sm font-medium text-gray-800">
                      {CHECK_LABELS[check.check] || check.check}
                    </span>
                    <p className="text-xs text-gray-500 mt-0.5">{check.message}</p>
                  </div>
                </div>

                {/* Broker health details */}
                {check.details && check.details.length > 0 && (
                  <div className="mt-2 ml-7 space-y-1">
                    {check.details.map((broker, j) => (
                      <div
                        key={j}
                        className="flex items-center gap-3 text-xs px-3 py-1.5 bg-gray-50 rounded"
                      >
                        <span className={`w-1.5 h-1.5 rounded-full ${
                          broker.healthy ? 'bg-green-500' : 'bg-red-500'
                        }`} />
                        <span className="text-gray-600 font-mono">Node {broker.node_id}</span>
                        <span className="text-gray-500">
                          {broker.hostname || broker.host}
                        </span>
                        <span className={`px-1.5 py-0.5 rounded text-xs font-medium ${
                          broker.healthy
                            ? 'bg-green-100 text-green-700'
                            : 'bg-red-100 text-red-700'
                        }`}>
                          {broker.status}
                        </span>
                        {broker.error && (
                          <span className="text-red-500 truncate max-w-xs" title={broker.error}>
                            {broker.error}
                          </span>
                        )}
                      </div>
                    ))}
                  </div>
                )}
              </div>
            ))}
          </div>
        </div>
      )}

      {/* Confirmation Dialog */}
      {showConfirm && (
        <div className="fixed inset-0 z-50 flex items-center justify-center bg-black/40">
          <div className="bg-white rounded-2xl shadow-2xl max-w-md w-full mx-4 p-6">
            <div className="flex items-center gap-3 mb-4">
              <AlertTriangle size={24} className="text-yellow-500" />
              <h3 className="text-lg font-semibold text-gray-900">Confirm Upgrade</h3>
            </div>
            <p className="text-sm text-gray-600 mb-2">
              You are about to perform a rolling upgrade:
            </p>
            <div className="bg-gray-50 rounded-lg px-4 py-3 mb-4 text-sm">
              <div className="flex justify-between">
                <span className="text-gray-500">From:</span>
                <span className="font-mono font-medium text-gray-800">{currentVersion}</span>
              </div>
              <div className="flex justify-between mt-1">
                <span className="text-gray-500">To:</span>
                <span className="font-mono font-medium text-green-700">{selectedVersion}</span>
              </div>
            </div>
            <p className="text-xs text-gray-500 mb-5">
              Each broker will be stopped, upgraded, and restarted one at a time.
              The cluster will remain available throughout the process but may
              experience brief leader elections.
            </p>
            <div className="flex gap-3 justify-end">
              <button
                onClick={() => setShowConfirm(false)}
                className="px-4 py-2 text-sm border rounded-lg hover:bg-gray-50"
              >
                Cancel
              </button>
              <button
                onClick={handleStartUpgrade}
                className="flex items-center gap-2 px-4 py-2 text-sm bg-green-600 text-white rounded-lg hover:bg-green-700"
              >
                <ArrowUpCircle size={15} />
                Start Rolling Upgrade
              </button>
            </div>
          </div>
        </div>
      )}

      {/* Upgrade Error */}
      {upgradeError && (
        <div className="flex items-start gap-2 bg-red-50 border border-red-200 rounded-xl px-4 py-3 text-sm text-red-700">
          <XCircle size={16} className="mt-0.5 shrink-0" />
          <span>{upgradeError}</span>
        </div>
      )}

      {/* Upgrade Progress */}
      {upgradeTask && (
        <div className="bg-white border rounded-xl overflow-hidden">
          {/* Status Header */}
          <div className={`px-5 py-4 border-b ${
            isCompleted ? 'bg-green-50' :
            isFailed ? 'bg-red-50' :
            'bg-blue-50'
          }`}>
            <div className="flex items-center gap-3">
              {isUpgrading && <Loader2 size={20} className="text-blue-600 animate-spin" />}
              {isCompleted && <CheckCircle size={20} className="text-green-600" />}
              {isFailed && <XCircle size={20} className="text-red-600" />}

              <div className="flex-1">
                <p className={`text-sm font-medium ${
                  isCompleted ? 'text-green-800' :
                  isFailed ? 'text-red-800' :
                  'text-blue-800'
                }`}>
                  {isUpgrading && 'Upgrade in Progress'}
                  {isCompleted && 'Upgrade Completed Successfully'}
                  {isFailed && 'Upgrade Failed'}
                </p>
                {progress && (
                  <p className="text-xs text-gray-500 mt-0.5">
                    {progress.phase === 'completed'
                      ? `All ${progress.total} broker(s) upgraded`
                      : progress.phase === 'failed'
                        ? `Failed during upgrade`
                        : progress.phase === 'pre_validation'
                          ? 'Running pre-upgrade validation...'
                          : progress.phase === 'post_verification'
                            ? 'Running post-upgrade verification...'
                            : progress.total > 0
                              ? `Broker ${progress.current} of ${progress.total}`
                              : 'Initializing...'}
                  </p>
                )}
              </div>

              {upgradeTask.started_at && (
                <div className="flex items-center gap-1.5 text-xs text-gray-400">
                  <Clock size={12} />
                  <span>
                    {new Date(upgradeTask.started_at).toLocaleTimeString()}
                  </span>
                </div>
              )}
            </div>

            {/* Progress Bar */}
            {isUpgrading && progress && progress.total > 0 && (
              <div className="mt-3">
                <div className="flex justify-between text-xs text-gray-500 mb-1">
                  <span>Progress</span>
                  <span>{progressPct}%</span>
                </div>
                <div className="w-full bg-gray-200 rounded-full h-2">
                  <div
                    className="bg-blue-600 h-2 rounded-full transition-all duration-500"
                    style={{ width: `${progressPct}%` }}
                  />
                </div>
              </div>
            )}

            {isCompleted && progress && (
              <div className="mt-3">
                <div className="w-full bg-green-200 rounded-full h-2">
                  <div className="bg-green-600 h-2 rounded-full w-full" />
                </div>
              </div>
            )}
          </div>

          {/* Error Detail */}
          {isFailed && upgradeTask.error && (
            <div className="px-5 py-3 bg-red-50 border-b text-sm text-red-700">
              <span className="font-medium">Error: </span>
              {upgradeTask.error}
            </div>
          )}

          {/* Log Toggle */}
          <div className="px-5 py-2 border-b bg-gray-50">
            <button
              onClick={() => setShowLogs(!showLogs)}
              className="flex items-center gap-2 text-xs text-gray-600 hover:text-gray-800"
            >
              <FileText size={13} />
              <span>Upgrade Logs ({upgradeTask.logs.length} entries)</span>
              {showLogs ? <ChevronUp size={13} /> : <ChevronDown size={13} />}
            </button>
          </div>

          {/* Log Output */}
          {showLogs && (
            <div className="bg-gray-900 max-h-96 overflow-y-auto font-mono text-xs">
              {upgradeTask.logs.length === 0 ? (
                <div className="px-4 py-6 text-gray-500 text-center">
                  Waiting for logs...
                </div>
              ) : (
                <div className="p-4 space-y-0.5">
                  {upgradeTask.logs.map((entry, i) => (
                    <div key={i} className="flex gap-2 leading-5">
                      <span className="text-gray-600 shrink-0 select-none">
                        {new Date(entry.timestamp).toLocaleTimeString()}
                      </span>
                      <span className={`shrink-0 uppercase w-12 text-right ${
                        entry.level === 'error' ? 'text-red-400' :
                        entry.level === 'warning' ? 'text-yellow-400' :
                        'text-blue-400'
                      }`}>
                        [{entry.level}]
                      </span>
                      <span className={`${
                        entry.level === 'error' ? 'text-red-300' :
                        entry.level === 'warning' ? 'text-yellow-200' :
                        entry.message.startsWith('---') ? 'text-green-300 font-semibold' :
                        'text-gray-300'
                      }`}>
                        {entry.message}
                      </span>
                    </div>
                  ))}
                  <div ref={logEndRef} />
                </div>
              )}
            </div>
          )}

          {/* Completed Actions */}
          {isCompleted && (
            <div className="px-5 py-4 bg-green-50 border-t flex items-center justify-between">
              <p className="text-sm text-green-700">
                All brokers have been upgraded. The cluster is now running the new version.
              </p>
              {upgradeTask.completed_at && (
                <span className="text-xs text-gray-400">
                  Completed at {new Date(upgradeTask.completed_at).toLocaleTimeString()}
                </span>
              )}
            </div>
          )}
        </div>
      )}
    </div>
  );
}
