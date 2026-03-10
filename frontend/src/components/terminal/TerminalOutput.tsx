import { useEffect, useRef } from 'react';

interface Props {
  logs: string[];
  status: string;
}

export default function TerminalOutput({ logs, status }: Props) {
  const endRef = useRef<HTMLDivElement>(null);

  useEffect(() => {
    endRef.current?.scrollIntoView({ behavior: 'smooth' });
  }, [logs]);

  return (
    <div className="bg-gray-900 rounded-xl overflow-hidden">
      <div className="flex items-center gap-2 px-4 py-2 bg-gray-800 border-b border-gray-700">
        <div className={`w-2 h-2 rounded-full ${
          status === 'running' ? 'bg-green-400 animate-pulse' :
          status === 'completed' ? 'bg-green-500' :
          status === 'error' ? 'bg-red-500' : 'bg-gray-500'
        }`} />
        <span className="text-xs text-gray-400 font-mono">
          {status === 'running' ? 'Deploying...' :
           status === 'completed' ? 'Deployment Complete' :
           status === 'completed_with_errors' ? 'Completed with Errors' :
           status === 'error' ? 'Deployment Failed' : 'Waiting...'}
        </span>
      </div>
      <div className="p-4 max-h-[500px] overflow-y-auto font-mono text-sm">
        {logs.map((line, i) => (
          <div
            key={i}
            className={`py-0.5 ${
              line.startsWith('ERROR') || line.includes('ERROR') ? 'text-red-400' :
              line.startsWith('WARN') || line.includes('WARN') ? 'text-yellow-400' :
              line.startsWith('===') ? 'text-blue-400 font-bold' :
              'text-green-300'
            }`}
          >
            {line}
          </div>
        ))}
        {logs.length === 0 && (
          <div className="text-gray-500">Waiting for deployment to start...</div>
        )}
        <div ref={endRef} />
      </div>
    </div>
  );
}
