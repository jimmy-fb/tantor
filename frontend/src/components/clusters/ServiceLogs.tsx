import { useState, useEffect, useRef } from 'react';
import { ScrollText, Play, Pause, RefreshCw, Filter, Download } from 'lucide-react';
import { getServiceLogs } from '../../lib/api';
import { getAccessToken } from '../../lib/auth';
import type { ServiceInfo } from '../../types';

interface Props {
  clusterId: string;
  services: ServiceInfo[];
}

export default function ServiceLogs({ clusterId, services }: Props) {
  const [selectedService, setSelectedService] = useState<string>('');
  const [logs, setLogs] = useState<string[]>([]);
  const [loading, setLoading] = useState(false);
  const [isLive, setIsLive] = useState(false);
  const [lineCount, setLineCount] = useState(200);
  const [priority, setPriority] = useState<string>('');
  const [grep, setGrep] = useState('');
  const [autoScroll, setAutoScroll] = useState(true);
  const wsRef = useRef<WebSocket | null>(null);
  const logContainerRef = useRef<HTMLDivElement>(null);

  // Auto-select first service
  useEffect(() => {
    if (services.length > 0 && !selectedService) {
      setSelectedService(services[0].id);
    }
  }, [services, selectedService]);

  // Auto-scroll when logs change
  useEffect(() => {
    if (autoScroll && logContainerRef.current) {
      logContainerRef.current.scrollTop = logContainerRef.current.scrollHeight;
    }
  }, [logs, autoScroll]);

  // Cleanup WebSocket on unmount
  useEffect(() => {
    return () => {
      if (wsRef.current) {
        wsRef.current.close();
        wsRef.current = null;
      }
    };
  }, []);

  const fetchLogs = async () => {
    if (!selectedService) return;
    setLoading(true);
    try {
      const data = await getServiceLogs(clusterId, {
        service_id: selectedService,
        lines: lineCount,
        priority: priority || undefined,
        grep: grep || undefined,
      });
      setLogs(data.lines || []);
    } catch {
      setLogs(['Error: Failed to fetch logs']);
    } finally {
      setLoading(false);
    }
  };

  useEffect(() => {
    if (selectedService && !isLive) {
      fetchLogs();
    }
  }, [selectedService]); // eslint-disable-line react-hooks/exhaustive-deps

  const toggleLive = () => {
    if (isLive) {
      // Stop live tailing
      if (wsRef.current) {
        wsRef.current.close();
        wsRef.current = null;
      }
      setIsLive(false);
    } else {
      // Start live tailing via WebSocket
      if (!selectedService) return;
      setIsLive(true);
      setLogs([]);

      const token = getAccessToken();
      const protocol = window.location.protocol === 'https:' ? 'wss:' : 'ws:';
      const ws = new WebSocket(
        `${protocol}//${window.location.host}/api/ws/logs/${clusterId}/${selectedService}?token=${token}`
      );

      ws.onmessage = (event) => {
        try {
          const data = JSON.parse(event.data);
          if (data.type === 'log') {
            setLogs(prev => {
              const updated = [...prev, data.line];
              // Keep last 3000 lines to prevent memory issues
              if (updated.length > 3000) return updated.slice(-2000);
              return updated;
            });
          }
        } catch {
          // non-JSON message
        }
      };

      ws.onclose = () => {
        setIsLive(false);
        wsRef.current = null;
      };

      ws.onerror = () => {
        setIsLive(false);
        wsRef.current = null;
      };

      wsRef.current = ws;
    }
  };

  const downloadLogs = () => {
    const blob = new Blob([logs.join('\n')], { type: 'text/plain' });
    const url = URL.createObjectURL(blob);
    const a = document.createElement('a');
    a.href = url;
    a.download = `tantor-logs-${Date.now()}.txt`;
    a.click();
    URL.revokeObjectURL(url);
  };

  const getLineColor = (line: string) => {
    const lower = line.toLowerCase();
    if (lower.includes('error') || lower.includes('fatal') || lower.includes('exception')) return 'text-red-400';
    if (lower.includes('warn')) return 'text-yellow-400';
    if (lower.includes('info')) return 'text-gray-300';
    if (lower.includes('debug')) return 'text-gray-500';
    return 'text-gray-300';
  };

  const selectedSvc = services.find(s => s.id === selectedService);

  return (
    <div className="space-y-4">
      {/* Controls */}
      <div className="flex items-center gap-3 flex-wrap">
        {/* Service selector */}
        <div className="flex items-center gap-2">
          <label className="text-sm font-medium text-gray-600">Service:</label>
          <select
            value={selectedService}
            onChange={(e) => {
              if (isLive) toggleLive(); // Stop live mode when switching
              setSelectedService(e.target.value);
            }}
            className="px-3 py-1.5 border border-gray-300 rounded-lg text-sm focus:ring-2 focus:ring-blue-500 focus:border-transparent"
          >
            {services.map(s => (
              <option key={s.id} value={s.id}>
                {s.role} (node {s.node_id})
              </option>
            ))}
          </select>
        </div>

        {/* Lines count */}
        <div className="flex items-center gap-2">
          <label className="text-sm font-medium text-gray-600">Lines:</label>
          <select
            value={lineCount}
            onChange={(e) => setLineCount(Number(e.target.value))}
            className="px-3 py-1.5 border border-gray-300 rounded-lg text-sm focus:ring-2 focus:ring-blue-500 focus:border-transparent"
          >
            <option value={50}>50</option>
            <option value={100}>100</option>
            <option value={200}>200</option>
            <option value={500}>500</option>
            <option value={1000}>1000</option>
          </select>
        </div>

        {/* Priority filter */}
        <div className="flex items-center gap-2">
          <Filter size={14} className="text-gray-500" />
          <select
            value={priority}
            onChange={(e) => setPriority(e.target.value)}
            className="px-3 py-1.5 border border-gray-300 rounded-lg text-sm focus:ring-2 focus:ring-blue-500 focus:border-transparent"
          >
            <option value="">All priorities</option>
            <option value="err">Errors only</option>
            <option value="warning">Warning+</option>
            <option value="info">Info+</option>
          </select>
        </div>

        {/* Grep filter */}
        <input
          type="text"
          value={grep}
          onChange={(e) => setGrep(e.target.value)}
          placeholder="Filter text..."
          className="px-3 py-1.5 border border-gray-300 rounded-lg text-sm focus:ring-2 focus:ring-blue-500 focus:border-transparent w-40"
          onKeyDown={(e) => e.key === 'Enter' && fetchLogs()}
        />

        <div className="flex-1" />

        {/* Action buttons */}
        <button
          onClick={fetchLogs}
          disabled={loading || isLive}
          className="flex items-center gap-1.5 px-3 py-1.5 bg-gray-200 hover:bg-gray-300 disabled:bg-gray-100 text-gray-700 rounded-lg text-sm font-medium transition-colors"
        >
          <RefreshCw size={14} className={loading ? 'animate-spin' : ''} />
          Refresh
        </button>

        <button
          onClick={toggleLive}
          className={`flex items-center gap-1.5 px-3 py-1.5 rounded-lg text-sm font-medium transition-colors ${
            isLive
              ? 'bg-red-600 hover:bg-red-700 text-white'
              : 'bg-green-600 hover:bg-green-700 text-white'
          }`}
        >
          {isLive ? <Pause size={14} /> : <Play size={14} />}
          {isLive ? 'Stop Live' : 'Live Tail'}
        </button>

        <button
          onClick={downloadLogs}
          disabled={logs.length === 0}
          className="flex items-center gap-1.5 px-3 py-1.5 bg-gray-200 hover:bg-gray-300 disabled:bg-gray-100 text-gray-700 rounded-lg text-sm font-medium transition-colors"
        >
          <Download size={14} />
        </button>
      </div>

      {/* Status bar */}
      <div className="flex items-center gap-3 text-xs text-gray-500">
        {selectedSvc && (
          <span className="bg-gray-100 px-2 py-1 rounded">
            {selectedSvc.role} • node {selectedSvc.node_id}
          </span>
        )}
        <span>{logs.length} lines</span>
        {isLive && (
          <span className="flex items-center gap-1.5 text-green-600 font-medium">
            <span className="w-2 h-2 bg-green-500 rounded-full animate-pulse" />
            Live
          </span>
        )}
        <div className="flex-1" />
        <label className="flex items-center gap-1.5 cursor-pointer">
          <input
            type="checkbox"
            checked={autoScroll}
            onChange={(e) => setAutoScroll(e.target.checked)}
            className="rounded"
          />
          Auto-scroll
        </label>
      </div>

      {/* Log output */}
      <div
        ref={logContainerRef}
        className="bg-gray-900 rounded-xl p-4 h-[500px] overflow-y-auto font-mono text-xs leading-relaxed"
      >
        {logs.length === 0 ? (
          <div className="flex items-center justify-center h-full text-gray-500">
            <div className="text-center">
              <ScrollText size={32} className="mx-auto mb-2 opacity-50" />
              <p>{loading ? 'Loading logs...' : 'No logs to display'}</p>
              <p className="text-gray-600 mt-1">Select a service and click Refresh or Live Tail</p>
            </div>
          </div>
        ) : (
          logs.map((line, i) => (
            <div key={i} className={`${getLineColor(line)} hover:bg-gray-800/50 px-1 rounded`}>
              {line}
            </div>
          ))
        )}
      </div>
    </div>
  );
}
