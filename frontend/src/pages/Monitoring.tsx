import { useState, useEffect } from 'react';
import { BarChart3, Server, Activity, CheckCircle, XCircle, Download, RefreshCw } from 'lucide-react';
import { getMonitoringStatus, installMonitoring, getMonitoringInstallStatus, getClusters, deployExporters } from '../lib/api';
import type { MonitoringStatus, Cluster } from '../types';

export default function Monitoring() {
  const [status, setStatus] = useState<MonitoringStatus | null>(null);
  const [clusters, setClusters] = useState<Cluster[]>([]);
  const [loading, setLoading] = useState(true);
  const [installing, setInstalling] = useState(false);
  const [installTaskId, setInstallTaskId] = useState<string | null>(null);
  const [installLogs, setInstallLogs] = useState<string[]>([]);
  const [deployingCluster, setDeployingCluster] = useState<string | null>(null);
  const [error, setError] = useState('');

  const fetchStatus = async () => {
    try {
      const data = await getMonitoringStatus();
      setStatus(data);
    } catch {
      // Monitoring not set up yet
      setStatus({
        prometheus_installed: false,
        grafana_installed: false,
        prometheus_running: false,
        grafana_running: false,
        prometheus_port: 9090,
        grafana_port: 3000,
        grafana_url: null,
        prometheus_url: null,
      });
    }
  };

  const fetchClusters = async () => {
    try {
      const data = await getClusters();
      setClusters(data.filter(c => c.state === 'running'));
    } catch {
      // ignore
    }
  };

  useEffect(() => {
    Promise.all([fetchStatus(), fetchClusters()]).finally(() => setLoading(false));
  }, []);

  // Poll for install progress
  useEffect(() => {
    if (!installTaskId) return;
    const interval = setInterval(async () => {
      try {
        const task = await getMonitoringInstallStatus(installTaskId);
        setInstallLogs(task.logs);
        if (task.status !== 'running') {
          clearInterval(interval);
          setInstalling(false);
          setInstallTaskId(null);
          fetchStatus();
        }
      } catch {
        clearInterval(interval);
        setInstalling(false);
      }
    }, 2000);
    return () => clearInterval(interval);
  }, [installTaskId]);

  const handleInstall = async () => {
    setInstalling(true);
    setError('');
    setInstallLogs([]);
    try {
      const result = await installMonitoring();
      setInstallTaskId(result.task_id);
    } catch (err: unknown) {
      setError((err as { response?: { data?: { detail?: string } } })?.response?.data?.detail || 'Installation failed');
      setInstalling(false);
    }
  };

  const handleDeployExporters = async (clusterId: string) => {
    setDeployingCluster(clusterId);
    try {
      await deployExporters(clusterId);
      // TODO: poll for deploy completion
    } catch (err: unknown) {
      setError((err as { response?: { data?: { detail?: string } } })?.response?.data?.detail || 'Exporter deployment failed');
    } finally {
      setDeployingCluster(null);
    }
  };

  if (loading) {
    return (
      <div className="flex items-center justify-center h-64">
        <div className="w-8 h-8 border-4 border-blue-500/30 border-t-blue-500 rounded-full animate-spin" />
      </div>
    );
  }

  return (
    <div className="space-y-6">
      <div className="flex items-center justify-between">
        <div>
          <h1 className="text-2xl font-bold text-gray-900 flex items-center gap-2">
            <BarChart3 size={24} />
            Monitoring
          </h1>
          <p className="text-gray-500 mt-1">Prometheus & Grafana cluster monitoring</p>
        </div>
        <button
          onClick={() => { fetchStatus(); fetchClusters(); }}
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

      {/* Infrastructure Status */}
      <div className="grid grid-cols-2 gap-4">
        <div className="bg-white border border-gray-200 rounded-xl p-6 shadow-sm">
          <div className="flex items-center justify-between mb-4">
            <h3 className="font-semibold text-gray-900 flex items-center gap-2">
              <Activity size={18} className="text-orange-500" />
              Prometheus
            </h3>
            {status?.prometheus_installed ? (
              <span className={`inline-flex items-center gap-1 px-2.5 py-1 rounded-full text-xs font-medium ${
                status.prometheus_running ? 'bg-green-100 text-green-700' : 'bg-red-100 text-red-700'
              }`}>
                {status.prometheus_running ? <CheckCircle size={12} /> : <XCircle size={12} />}
                {status.prometheus_running ? 'Running' : 'Stopped'}
              </span>
            ) : (
              <span className="text-xs text-gray-400">Not installed</span>
            )}
          </div>
          {status?.prometheus_installed ? (
            <p className="text-sm text-gray-500">Port: {status.prometheus_port}</p>
          ) : (
            <p className="text-sm text-gray-400">Install Prometheus to enable metrics collection</p>
          )}
        </div>

        <div className="bg-white border border-gray-200 rounded-xl p-6 shadow-sm">
          <div className="flex items-center justify-between mb-4">
            <h3 className="font-semibold text-gray-900 flex items-center gap-2">
              <BarChart3 size={18} className="text-green-500" />
              Grafana
            </h3>
            {status?.grafana_installed ? (
              <span className={`inline-flex items-center gap-1 px-2.5 py-1 rounded-full text-xs font-medium ${
                status.grafana_running ? 'bg-green-100 text-green-700' : 'bg-red-100 text-red-700'
              }`}>
                {status.grafana_running ? <CheckCircle size={12} /> : <XCircle size={12} />}
                {status.grafana_running ? 'Running' : 'Stopped'}
              </span>
            ) : (
              <span className="text-xs text-gray-400">Not installed</span>
            )}
          </div>
          {status?.grafana_installed ? (
            <p className="text-sm text-gray-500">Port: {status.grafana_port}</p>
          ) : (
            <p className="text-sm text-gray-400">Install Grafana to enable dashboards</p>
          )}
        </div>
      </div>

      {/* Install Button */}
      {(!status?.prometheus_installed || !status?.grafana_installed) && (
        <div className="bg-blue-50 border border-blue-200 rounded-xl p-6">
          <h3 className="font-semibold text-blue-900 mb-2">Setup Monitoring Infrastructure</h3>
          <p className="text-sm text-blue-700 mb-4">
            Install Prometheus and Grafana on this server to enable cluster monitoring.
            Node exporters and JMX exporters will be deployed to cluster hosts.
          </p>
          <button
            onClick={handleInstall}
            disabled={installing}
            className="flex items-center gap-2 px-4 py-2 bg-blue-600 hover:bg-blue-700 disabled:bg-blue-400 text-white rounded-lg font-medium transition-colors"
          >
            {installing ? (
              <div className="w-4 h-4 border-2 border-white/30 border-t-white rounded-full animate-spin" />
            ) : (
              <Download size={16} />
            )}
            {installing ? 'Installing...' : 'Install Prometheus & Grafana'}
          </button>
        </div>
      )}

      {/* Install Logs */}
      {installLogs.length > 0 && (
        <div className="bg-gray-900 rounded-xl p-4 max-h-64 overflow-y-auto">
          <pre className="text-xs text-gray-300 font-mono whitespace-pre-wrap">
            {installLogs.join('\n')}
          </pre>
        </div>
      )}

      {/* Cluster Exporters */}
      {status?.prometheus_installed && clusters.length > 0 && (
        <div className="bg-white border border-gray-200 rounded-xl p-6 shadow-sm">
          <h3 className="font-semibold text-gray-900 mb-4 flex items-center gap-2">
            <Server size={18} />
            Cluster Exporters
          </h3>
          <p className="text-sm text-gray-500 mb-4">
            Deploy node_exporter and JMX exporter to cluster hosts for metrics collection.
          </p>
          <div className="space-y-3">
            {clusters.map(cluster => (
              <div key={cluster.id} className="flex items-center justify-between p-3 bg-gray-50 rounded-lg">
                <div>
                  <p className="font-medium text-gray-900">{cluster.name}</p>
                  <p className="text-xs text-gray-500">Kafka {cluster.kafka_version} • {cluster.mode}</p>
                </div>
                <button
                  onClick={() => handleDeployExporters(cluster.id)}
                  disabled={deployingCluster === cluster.id}
                  className="flex items-center gap-2 px-3 py-1.5 bg-green-600 hover:bg-green-700 disabled:bg-green-400 text-white rounded-lg text-sm font-medium transition-colors"
                >
                  {deployingCluster === cluster.id ? (
                    <div className="w-3 h-3 border-2 border-white/30 border-t-white rounded-full animate-spin" />
                  ) : (
                    <Download size={14} />
                  )}
                  Deploy Exporters
                </button>
              </div>
            ))}
          </div>
        </div>
      )}

      {/* Grafana Dashboards */}
      {status?.grafana_installed && status?.grafana_running && (
        <div className="bg-white border border-gray-200 rounded-xl shadow-sm overflow-hidden">
          <div className="p-4 border-b border-gray-200">
            <h3 className="font-semibold text-gray-900 flex items-center gap-2">
              <BarChart3 size={18} />
              Grafana Dashboards
            </h3>
          </div>
          <div className="p-4">
            {(() => {
              const grafanaBase = status.grafana_url || `http://localhost:${status.grafana_port}`;
              return (
                <>
                  <p className="text-sm text-gray-500 mb-4">
                    Access Grafana at{' '}
                    <a href={grafanaBase} target="_blank" rel="noopener noreferrer" className="text-blue-600 hover:underline">
                      {grafanaBase}
                    </a>
                  </p>
                  <iframe
                    src={`${grafanaBase}/d/kafka-overview?orgId=1&kiosk`}
                    className="w-full h-[600px] border border-gray-200 rounded-lg"
                    title="Grafana Dashboard"
                  />
                </>
              );
            })()}
          </div>
        </div>
      )}

      {/* Empty state */}
      {status?.prometheus_installed && status?.grafana_installed && clusters.length === 0 && (
        <div className="bg-gray-50 border border-gray-200 rounded-xl p-8 text-center">
          <Server size={32} className="mx-auto text-gray-400 mb-3" />
          <h3 className="font-semibold text-gray-700">No Running Clusters</h3>
          <p className="text-sm text-gray-500 mt-1">
            Deploy a cluster first, then come back to set up monitoring exporters.
          </p>
        </div>
      )}
    </div>
  );
}
