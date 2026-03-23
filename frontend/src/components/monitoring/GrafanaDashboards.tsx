import { useState, useEffect } from 'react';
import { ExternalLink, Clock, RefreshCw, Server, Loader2 } from 'lucide-react';
import { getHosts, deployMonitoring, getGrafanaInfo } from '../../lib/api';
import type { Host } from '../../types';

const TIME_RANGES = [
  { label: '1 Hour', value: 'now-1h' },
  { label: '6 Hours', value: 'now-6h' },
  { label: '24 Hours', value: 'now-24h' },
  { label: '7 Days', value: 'now-7d' },
  { label: '30 Days', value: 'now-30d' },
  { label: '6 Months', value: 'now-180d' },
];

interface GrafanaInfo {
  deployed: boolean;
  grafana_url?: string;
  prometheus_url?: string;
  grafana_port?: number;
  prometheus_port?: number;
}

interface Props {
  clusterId: string;
}

export default function GrafanaDashboards({ clusterId }: Props) {
  const [grafanaInfo, setGrafanaInfo] = useState<GrafanaInfo | null>(null);
  const [loading, setLoading] = useState(true);
  const [deploying, setDeploying] = useState(false);
  const [timeRange, setTimeRange] = useState('now-1h');
  const [hosts, setHosts] = useState<Host[]>([]);
  const [selectedHostId, setSelectedHostId] = useState('');
  const [deployResult, setDeployResult] = useState<string | null>(null);
  const [iframeKey, setIframeKey] = useState(0);

  useEffect(() => {
    Promise.all([
      getGrafanaInfo(clusterId),
      getHosts(),
    ]).then(([info, hostList]) => {
      setGrafanaInfo(info);
      setHosts(hostList);
      if (hostList.length > 0) setSelectedHostId(hostList[0].id);
    }).finally(() => setLoading(false));
  }, [clusterId]);

  const handleDeploy = async () => {
    if (!selectedHostId) return;
    setDeploying(true);
    setDeployResult(null);
    try {
      await deployMonitoring(clusterId, {
        monitoring_host_id: selectedHostId,
        grafana_port: 3000,
        prometheus_port: 9090,
      });
      setDeployResult('Monitoring stack deployed successfully!');
      const info = await getGrafanaInfo(clusterId);
      setGrafanaInfo(info);
    } catch (err: unknown) {
      const msg = err instanceof Error ? err.message : 'Deployment failed';
      setDeployResult(`Error: ${msg}`);
    } finally {
      setDeploying(false);
    }
  };

  if (loading) {
    return (
      <div className="flex items-center justify-center h-64">
        <div className="w-8 h-8 border-4 border-blue-500/30 border-t-blue-500 rounded-full animate-spin" />
      </div>
    );
  }

  if (!grafanaInfo?.deployed) {
    return (
      <div className="bg-white border rounded-xl p-8 text-center">
        <Server size={48} className="mx-auto text-gray-300 mb-4" />
        <h3 className="text-lg font-semibold text-gray-700 mb-2">Deploy Monitoring Stack</h3>
        <p className="text-gray-500 mb-6 max-w-md mx-auto">
          Deploy Prometheus + Grafana + JMX Exporter to get rich time-series dashboards
          for your Kafka cluster.
        </p>
        <div className="max-w-sm mx-auto space-y-4">
          <div>
            <label className="block text-sm font-medium text-gray-700 mb-1 text-left">Deploy On Host</label>
            <select
              value={selectedHostId}
              onChange={e => setSelectedHostId(e.target.value)}
              className="w-full border rounded-lg px-3 py-2 text-sm"
            >
              {hosts.map(h => (
                <option key={h.id} value={h.id}>{h.hostname} ({h.ip_address})</option>
              ))}
            </select>
          </div>
          <button
            onClick={handleDeploy}
            disabled={deploying || !selectedHostId}
            className="w-full flex items-center justify-center gap-2 px-4 py-2 bg-blue-600 text-white rounded-lg hover:bg-blue-700 disabled:opacity-50"
          >
            {deploying ? (
              <><Loader2 size={16} className="animate-spin" /> Deploying...</>
            ) : (
              'Deploy Prometheus + Grafana'
            )}
          </button>
          {deployResult && (
            <p className={`text-sm ${deployResult.startsWith('Error') ? 'text-red-600' : 'text-green-600'}`}>
              {deployResult}
            </p>
          )}
        </div>
      </div>
    );
  }

  const grafanaUrl = grafanaInfo.grafana_url;
  const iframeUrl = `${grafanaUrl}/?orgId=1&from=${timeRange}&to=now&kiosk=tv&theme=light`;

  return (
    <div className="space-y-4">
      <div className="flex items-center justify-between">
        <div className="flex items-center gap-3">
          <Clock size={16} className="text-gray-400" />
          <div className="flex gap-1">
            {TIME_RANGES.map(tr => (
              <button
                key={tr.value}
                onClick={() => setTimeRange(tr.value)}
                className={`px-3 py-1.5 text-xs rounded-lg transition-colors ${
                  timeRange === tr.value
                    ? 'bg-blue-600 text-white'
                    : 'bg-gray-100 text-gray-600 hover:bg-gray-200'
                }`}
              >
                {tr.label}
              </button>
            ))}
          </div>
        </div>
        <div className="flex items-center gap-2">
          <a
            href={grafanaUrl ?? '#'}
            target="_blank"
            rel="noopener noreferrer"
            className="flex items-center gap-1.5 px-3 py-1.5 text-sm text-blue-600 hover:text-blue-800"
          >
            <ExternalLink size={14} /> Open Grafana
          </a>
          <button
            onClick={() => setIframeKey(k => k + 1)}
            className="flex items-center gap-1.5 px-3 py-1.5 text-sm border rounded-lg hover:bg-gray-50"
          >
            <RefreshCw size={14} /> Refresh
          </button>
        </div>
      </div>

      <div className="bg-white border rounded-xl overflow-hidden">
        <iframe
          key={iframeKey}
          src={iframeUrl}
          className="w-full border-0"
          style={{ height: 'calc(100vh - 280px)', minHeight: '600px' }}
          title="Grafana Dashboard"
        />
      </div>
    </div>
  );
}
