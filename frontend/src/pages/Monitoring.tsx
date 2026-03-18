import { useState, useEffect, useCallback } from 'react';
import { BarChart3, Cpu, HardDrive, Activity, RefreshCw, Server, Wifi, Database, Clock, MemoryStick } from 'lucide-react';
import { getClusters, getClusterMetrics } from '../lib/api';
import type { Cluster } from '../types';

interface NodeMetrics {
  host_id: string;
  hostname: string;
  ip_address: string;
  role: string;
  node_id: number;
  status: string;
  system: {
    uptime?: string;
    cpu_cores?: number;
    cpu_usage_pct?: number;
    load_1m?: number;
    load_5m?: number;
    load_15m?: number;
    memory_total_mb?: number;
    memory_used_mb?: number;
    memory_available_mb?: number;
    memory_usage_pct?: number;
    error?: string;
  };
  kafka: {
    status?: string;
    pid?: number;
    uptime?: string;
    uptime_seconds?: number;
    memory_rss_mb?: number;
    data_size_mb?: number;
    log_size_mb?: number;
    topics?: number;
    partitions?: number;
    open_fds?: number;
    connections?: number;
    error?: string;
  };
  disk: {
    root?: { total_mb: number; used_mb: number; available_mb: number; usage_pct: number };
    data?: { total_mb: number; used_mb: number; available_mb: number; usage_pct: number };
    error?: string;
  };
}

interface ClusterMetrics {
  cluster_id: string;
  cluster_name: string;
  nodes: NodeMetrics[];
}

function ProgressBar({ value, max = 100, color = 'blue' }: { value: number; max?: number; color?: string }) {
  const pct = Math.min((value / max) * 100, 100);
  const colorMap: Record<string, string> = {
    blue: pct > 80 ? 'bg-red-500' : pct > 60 ? 'bg-yellow-500' : 'bg-blue-500',
    green: pct > 80 ? 'bg-red-500' : pct > 60 ? 'bg-yellow-500' : 'bg-green-500',
    purple: pct > 80 ? 'bg-red-500' : pct > 60 ? 'bg-yellow-500' : 'bg-purple-500',
  };
  return (
    <div className="w-full bg-gray-200 rounded-full h-2.5">
      <div className={`${colorMap[color] || colorMap.blue} h-2.5 rounded-full transition-all duration-500`} style={{ width: `${pct}%` }} />
    </div>
  );
}

function MetricCard({ icon: Icon, label, value, sub }: { icon: typeof Cpu; label: string; value: string | number; sub?: string }) {
  return (
    <div className="bg-gray-50 border border-gray-100 rounded-lg p-3">
      <div className="flex items-center gap-1.5 mb-1">
        <Icon size={13} className="text-gray-400" />
        <span className="text-[11px] font-medium text-gray-500 uppercase tracking-wide">{label}</span>
      </div>
      <p className="text-lg font-bold text-gray-800">{value}</p>
      {sub && <p className="text-[11px] text-gray-400 mt-0.5">{sub}</p>}
    </div>
  );
}

export default function Monitoring() {
  const [clusters, setClusters] = useState<Cluster[]>([]);
  const [selectedCluster, setSelectedCluster] = useState<string>('');
  const [metrics, setMetrics] = useState<ClusterMetrics | null>(null);
  const [loading, setLoading] = useState(true);
  const [refreshing, setRefreshing] = useState(false);
  const [autoRefresh, setAutoRefresh] = useState(false);

  useEffect(() => {
    getClusters().then((data: Cluster[]) => {
      const running = data.filter((c: Cluster) => c.state === 'running');
      setClusters(running);
      if (running.length > 0) setSelectedCluster(running[0].id);
    }).finally(() => setLoading(false));
  }, []);

  const fetchMetrics = useCallback(async (silent = false) => {
    if (!selectedCluster) return;
    if (!silent) setRefreshing(true);
    try {
      const data = await getClusterMetrics(selectedCluster);
      setMetrics(data);
    } catch { /* ignore */ }
    if (!silent) setRefreshing(false);
  }, [selectedCluster]);

  useEffect(() => {
    if (selectedCluster) fetchMetrics();
  }, [selectedCluster, fetchMetrics]);

  // Auto-refresh every 30s
  useEffect(() => {
    if (!autoRefresh || !selectedCluster) return;
    const interval = setInterval(() => fetchMetrics(true), 30000);
    return () => clearInterval(interval);
  }, [autoRefresh, selectedCluster, fetchMetrics]);

  if (loading) {
    return (
      <div className="flex items-center justify-center h-64">
        <div className="w-8 h-8 border-4 border-blue-500/30 border-t-blue-500 rounded-full animate-spin" />
      </div>
    );
  }

  if (clusters.length === 0) {
    return (
      <div className="space-y-6">
        <h1 className="text-2xl font-bold text-gray-900 flex items-center gap-2">
          <BarChart3 size={24} /> Monitoring
        </h1>
        <div className="bg-gray-50 border border-gray-200 rounded-xl p-12 text-center">
          <Server size={40} className="mx-auto text-gray-300 mb-4" />
          <h3 className="text-lg font-semibold text-gray-600">No Running Clusters</h3>
          <p className="text-gray-400 mt-2">Deploy a Kafka cluster first, then monitoring metrics will appear here automatically.</p>
        </div>
      </div>
    );
  }

  return (
    <div className="space-y-6">
      {/* Header */}
      <div className="flex items-center justify-between">
        <div>
          <h1 className="text-2xl font-bold text-gray-900 flex items-center gap-2">
            <BarChart3 size={24} /> Monitoring
          </h1>
          <p className="text-gray-500 mt-1">Live Kafka & system metrics</p>
        </div>
        <div className="flex items-center gap-3">
          {clusters.length > 1 && (
            <select
              value={selectedCluster}
              onChange={e => setSelectedCluster(e.target.value)}
              className="border border-gray-300 rounded-lg px-3 py-2 text-sm"
            >
              {clusters.map(c => (
                <option key={c.id} value={c.id}>{c.name}</option>
              ))}
            </select>
          )}
          <label className="flex items-center gap-2 text-sm text-gray-600 cursor-pointer">
            <input
              type="checkbox"
              checked={autoRefresh}
              onChange={e => setAutoRefresh(e.target.checked)}
              className="rounded border-gray-300"
            />
            Auto (30s)
          </label>
          <button
            onClick={() => fetchMetrics()}
            disabled={refreshing}
            className="flex items-center gap-2 px-3 py-2 text-gray-600 hover:text-gray-900 border border-gray-300 rounded-lg hover:bg-gray-50 transition-colors"
          >
            <RefreshCw size={16} className={refreshing ? 'animate-spin' : ''} />
            Refresh
          </button>
        </div>
      </div>

      {/* Nodes */}
      {metrics?.nodes.map(node => (
        <div key={node.host_id} className="bg-white border border-gray-200 rounded-xl shadow-sm overflow-hidden">
          {/* Node Header */}
          <div className="px-6 py-4 border-b border-gray-100 bg-gray-50 flex items-center justify-between">
            <div className="flex items-center gap-3">
              <Server size={20} className="text-gray-500" />
              <div>
                <h3 className="font-semibold text-gray-900">{node.hostname}</h3>
                <p className="text-xs text-gray-500">{node.ip_address} · {node.role} · Node {node.node_id}</p>
              </div>
            </div>
            <span className={`inline-flex items-center gap-1.5 px-3 py-1 rounded-full text-xs font-medium ${
              node.kafka.status === 'active' ? 'bg-green-100 text-green-700' : 'bg-red-100 text-red-700'
            }`}>
              <span className={`w-2 h-2 rounded-full ${node.kafka.status === 'active' ? 'bg-green-500' : 'bg-red-500'}`} />
              Kafka {node.kafka.status === 'active' ? 'Running' : node.kafka.status || 'Unknown'}
            </span>
          </div>

          <div className="p-6 space-y-6">
            {/* Kafka Metrics */}
            <div>
              <h4 className="text-sm font-semibold text-gray-700 mb-3 flex items-center gap-2">
                <Activity size={14} /> Kafka Broker
              </h4>
              <div className="grid grid-cols-2 sm:grid-cols-3 lg:grid-cols-6 gap-3">
                <MetricCard icon={Clock} label="Uptime" value={node.kafka.uptime || '-'} />
                <MetricCard icon={MemoryStick} label="Memory (RSS)" value={`${node.kafka.memory_rss_mb || 0} MB`} />
                <MetricCard icon={Database} label="Data Size" value={`${node.kafka.data_size_mb || 0} MB`} />
                <MetricCard icon={BarChart3} label="Topics" value={node.kafka.topics ?? 0} />
                <MetricCard icon={HardDrive} label="Partitions" value={node.kafka.partitions ?? 0} />
                <MetricCard icon={Wifi} label="Connections" value={node.kafka.connections ?? 0} />
              </div>
            </div>

            {/* System Metrics */}
            <div>
              <h4 className="text-sm font-semibold text-gray-700 mb-3 flex items-center gap-2">
                <Cpu size={14} /> System Resources
              </h4>
              <div className="grid grid-cols-1 sm:grid-cols-3 gap-4">
                {/* CPU */}
                <div className="space-y-2">
                  <div className="flex justify-between text-sm">
                    <span className="text-gray-600">CPU ({node.system.cpu_cores || 0} cores)</span>
                    <span className="font-medium">{node.system.cpu_usage_pct ?? 0}%</span>
                  </div>
                  <ProgressBar value={node.system.cpu_usage_pct ?? 0} color="blue" />
                  <p className="text-xs text-gray-400">Load: {node.system.load_1m ?? 0} / {node.system.load_5m ?? 0} / {node.system.load_15m ?? 0}</p>
                </div>

                {/* Memory */}
                <div className="space-y-2">
                  <div className="flex justify-between text-sm">
                    <span className="text-gray-600">Memory</span>
                    <span className="font-medium">{node.system.memory_used_mb ?? 0} / {node.system.memory_total_mb ?? 0} MB</span>
                  </div>
                  <ProgressBar value={node.system.memory_usage_pct ?? 0} color="green" />
                  <p className="text-xs text-gray-400">{node.system.memory_available_mb ?? 0} MB available</p>
                </div>

                {/* Disk */}
                <div className="space-y-2">
                  <div className="flex justify-between text-sm">
                    <span className="text-gray-600">Disk (data)</span>
                    <span className="font-medium">{node.disk.data?.usage_pct ?? node.disk.root?.usage_pct ?? 0}%</span>
                  </div>
                  <ProgressBar value={node.disk.data?.usage_pct ?? node.disk.root?.usage_pct ?? 0} color="purple" />
                  <p className="text-xs text-gray-400">
                    {((node.disk.data?.available_mb ?? node.disk.root?.available_mb ?? 0) / 1024).toFixed(1)} GB free
                  </p>
                </div>
              </div>
            </div>
          </div>
        </div>
      ))}
    </div>
  );
}
