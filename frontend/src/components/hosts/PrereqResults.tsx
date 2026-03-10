import { CheckCircle, XCircle, AlertTriangle } from 'lucide-react';
import type { PrereqResult } from '../../types';

interface Props {
  result: PrereqResult;
}

const statusIcon = {
  pass: <CheckCircle size={16} className="text-green-500" />,
  fail: <XCircle size={16} className="text-red-500" />,
  warn: <AlertTriangle size={16} className="text-yellow-500" />,
};

const statusBg = {
  pass: 'bg-green-50 border-green-200',
  fail: 'bg-red-50 border-red-200',
  warn: 'bg-yellow-50 border-yellow-200',
};

export default function PrereqResults({ result }: Props) {
  return (
    <div className="space-y-2">
      <div className="flex items-center gap-2 mb-3">
        {result.all_passed ? (
          <CheckCircle size={20} className="text-green-500" />
        ) : (
          <XCircle size={20} className="text-red-500" />
        )}
        <span className="font-medium text-sm">
          {result.all_passed ? 'All checks passed' : 'Some checks failed'}
        </span>
      </div>
      {result.checks.map((check, i) => (
        <div
          key={i}
          className={`flex items-start gap-3 p-3 rounded-lg border ${statusBg[check.status]}`}
        >
          <div className="mt-0.5">{statusIcon[check.status]}</div>
          <div className="flex-1 min-w-0">
            <div className="text-sm font-medium text-gray-900">{check.name}</div>
            <div className="text-sm text-gray-600">{check.message}</div>
            {check.details && (
              <pre className="mt-1 text-xs text-gray-500 overflow-x-auto">{check.details}</pre>
            )}
          </div>
        </div>
      ))}
    </div>
  );
}
