import { useState, useEffect } from 'react';
import {
  Globe, RefreshCw, ExternalLink, CheckCircle, XCircle,
  AlertTriangle, Loader2,
} from 'lucide-react';
import axios from 'axios';
import { getAccessToken, isAdmin } from '../lib/auth';

const authApi = axios.create({ baseURL: '/api' });
authApi.interceptors.request.use((config) => {
  const token = getAccessToken();
  if (token) config.headers.Authorization = `Bearer ${token}`;
  return config;
});

interface LocalKafkaUIStatus {
  is_running: boolean;
  config_exists: boolean;
  cluster_count: number;
  url: string | null;
}

export default function KafkaExplorer() {
  const admin = isAdmin();
  const [status, setStatus] = useState<LocalKafkaUIStatus | null>(null);
  const [loading, setLoading] = useState(true);
  const [syncing, setSyncing] = useState(false);
  const [syncResult, setSyncResult] = useState<string | null>(null);
  const [error, setError] = useState('');

  const fetchStatus = async () => {
    try {
      const { data } = await authApi.get<LocalKafkaUIStatus>('/kafka-ui/local/status');
      setStatus(data);
      setError('');
    } catch {
      setStatus(null);
      setError('Kafka UI service is not installed or not reachable.');
    } finally {
      setLoading(false);
    }
  };

  const handleSync = async () => {
    setSyncing(true);
    setSyncResult(null);
    try {
      const { data } = await authApi.post('/kafka-ui/local/sync');
      setSyncResult(`Synced ${data.clusters_synced} cluster(s): ${data.cluster_names.join(', ') || 'none'}`);
      await fetchStatus();
    } catch (err: unknown) {
      const msg = (err as { response?: { data?: { detail?: string } } })?.response?.data?.detail || 'Sync failed';
      setSyncResult(`Error: ${msg}`);
    } finally {
      setSyncing(false);
    }
  };

  useEffect(() => {
    fetchStatus();
  }, []);

  if (loading) {
    return (
      <div className="flex items-center justify-center h-64">
        <Loader2 size={32} className="animate-spin text-blue-500" />
      </div>
    );
  }

  return (
    <div className="space-y-6">
      {/* Header */}
      <div className="flex items-center justify-between">
        <div>
          <h1 className="text-2xl font-bold text-gray-900 flex items-center gap-2">
            <Globe size={24} />
            Kafka UI
          </h1>
          <p className="text-gray-500 mt-1">
            Browse topics, consumer groups, messages, schemas, and cluster configuration
          </p>
        </div>
        <div className="flex items-center gap-2">
          {admin && (
            <button
              onClick={handleSync}
              disabled={syncing}
              className="flex items-center gap-2 px-3 py-2 text-sm border border-gray-300 rounded-lg hover:bg-gray-50 disabled:opacity-50"
            >
              {syncing ? <Loader2 size={16} className="animate-spin" /> : <RefreshCw size={16} />}
              Sync Clusters
            </button>
          )}
          {status?.is_running && (
            <a
              href="/kafka-ui/"
              target="_blank"
              rel="noopener noreferrer"
              className="flex items-center gap-2 px-4 py-2 bg-blue-600 text-white text-sm rounded-lg hover:bg-blue-700"
            >
              <ExternalLink size={16} />
              Open Full Screen
            </a>
          )}
        </div>
      </div>

      {/* Sync result */}
      {syncResult && (
        <div className={`flex items-start gap-2 p-3 rounded-lg text-sm ${
          syncResult.startsWith('Error')
            ? 'bg-red-50 border border-red-200 text-red-700'
            : 'bg-green-50 border border-green-200 text-green-700'
        }`}>
          {syncResult.startsWith('Error') ? <AlertTriangle size={16} className="mt-0.5" /> : <CheckCircle size={16} className="mt-0.5" />}
          {syncResult}
        </div>
      )}

      {/* Error state */}
      {error && (
        <div className="bg-amber-50 border border-amber-200 rounded-xl p-6 text-center">
          <AlertTriangle size={40} className="mx-auto text-amber-400 mb-3" />
          <h3 className="text-lg font-semibold text-gray-700">Kafka UI Not Available</h3>
          <p className="text-sm text-gray-500 mt-2 max-w-lg mx-auto">
            {error} The Kafka UI service (kafbat/kafka-ui) will be set up during installation.
            If you just deployed a cluster, click "Sync Clusters" to configure it.
          </p>
        </div>
      )}

      {/* Status info */}
      {status && !error && (
        <>
          <div className="flex items-center gap-4 text-sm">
            <span className={`inline-flex items-center gap-1.5 px-3 py-1 rounded-full font-medium ${
              status.is_running ? 'bg-green-100 text-green-700' : 'bg-red-100 text-red-700'
            }`}>
              {status.is_running ? <CheckCircle size={14} /> : <XCircle size={14} />}
              {status.is_running ? 'Running' : 'Stopped'}
            </span>
            <span className="text-gray-500">
              {status.cluster_count} cluster{status.cluster_count !== 1 ? 's' : ''} configured
            </span>
          </div>

          {/* Embedded iframe */}
          {status.is_running ? (
            <div className="border border-gray-200 rounded-xl overflow-hidden shadow-sm" style={{ height: 'calc(100vh - 260px)' }}>
              <iframe
                src="/kafka-ui/"
                className="w-full h-full border-0"
                title="Kafka UI"
              />
            </div>
          ) : (
            <div className="bg-gray-50 border border-gray-200 rounded-xl p-12 text-center">
              <Globe size={40} className="mx-auto text-gray-300 mb-4" />
              <h3 className="text-lg font-semibold text-gray-600">Kafka UI Service Not Running</h3>
              <p className="text-sm text-gray-400 mt-2">
                Deploy a Kafka cluster first, then click "Sync Clusters" to configure and start the Kafka UI.
              </p>
            </div>
          )}
        </>
      )}
    </div>
  );
}
