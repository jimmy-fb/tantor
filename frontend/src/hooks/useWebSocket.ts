import { useState, useEffect, useRef, useCallback } from 'react';
import { getAccessToken } from '../lib/auth';

interface WSMessage {
  type: 'log' | 'status' | 'error';
  message?: string;
  status?: string;
}

export function useDeploymentLogs(taskId: string | null) {
  const [logs, setLogs] = useState<string[]>([]);
  const [status, setStatus] = useState<string>('pending');
  const wsRef = useRef<WebSocket | null>(null);

  const connect = useCallback(() => {
    if (!taskId) return;

    const token = getAccessToken();
    const protocol = window.location.protocol === 'https:' ? 'wss:' : 'ws:';
    const ws = new WebSocket(`${protocol}//${window.location.host}/api/ws/deploy/${taskId}?token=${token}`);
    wsRef.current = ws;

    ws.onmessage = (event) => {
      const data: WSMessage = JSON.parse(event.data);
      if (data.type === 'log' && data.message) {
        setLogs(prev => [...prev, data.message!]);
      } else if (data.type === 'status' && data.status) {
        setStatus(data.status);
      } else if (data.type === 'error' && data.message) {
        setLogs(prev => [...prev, `ERROR: ${data.message}`]);
        setStatus('error');
      }
    };

    ws.onclose = () => {
      wsRef.current = null;
    };
  }, [taskId]);

  useEffect(() => {
    connect();
    return () => {
      wsRef.current?.close();
    };
  }, [connect]);

  return { logs, status };
}
