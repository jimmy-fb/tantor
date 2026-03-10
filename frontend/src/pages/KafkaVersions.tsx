import { useState, useEffect, useRef } from 'react';
import {
  Package, Upload, CheckCircle, XCircle, ChevronDown, ChevronUp,
  Shield, Sparkles, ArrowUpCircle, Loader2,
} from 'lucide-react';
import type { KafkaVersionInfo } from '../types';
import { getKafkaVersions, uploadKafkaBinary } from '../lib/api';

export default function KafkaVersions() {
  const [versions, setVersions] = useState<KafkaVersionInfo[]>([]);
  const [loading, setLoading] = useState(true);
  const [expanded, setExpanded] = useState<string | null>(null);
  const [uploading, setUploading] = useState(false);
  const [uploadMsg, setUploadMsg] = useState<{ text: string; ok: boolean } | null>(null);
  const fileRef = useRef<HTMLInputElement>(null);

  const fetchVersions = async () => {
    setLoading(true);
    try {
      const data = await getKafkaVersions();
      setVersions(data);
    } finally {
      setLoading(false);
    }
  };

  useEffect(() => {
    fetchVersions();
  }, []);

  const handleUpload = async (e: React.ChangeEvent<HTMLInputElement>) => {
    const file = e.target.files?.[0];
    if (!file) return;
    setUploading(true);
    setUploadMsg(null);
    try {
      const res = await uploadKafkaBinary(file);
      setUploadMsg({ text: `Uploaded ${res.filename} (${res.size_mb} MB)`, ok: true });
      fetchVersions();
    } catch (err: unknown) {
      const axErr = err as { response?: { data?: { detail?: string } } };
      const detail = axErr?.response?.data?.detail;
      setUploadMsg({ text: detail || 'Upload failed. Ensure filename matches kafka_{scala}-{version}.tgz', ok: false });
    } finally {
      setUploading(false);
      if (fileRef.current) fileRef.current.value = '';
    }
  };

  return (
    <div>
      <div className="flex items-center justify-between mb-6">
        <div>
          <h1 className="text-2xl font-bold text-gray-900">Kafka Versions</h1>
          <p className="text-sm text-gray-500 mt-1">
            Manage locally available Kafka binaries for airgapped deployment
          </p>
        </div>
        <div className="flex items-center gap-3">
          {uploadMsg && (
            <span className={`text-sm ${uploadMsg.ok ? 'text-green-600' : 'text-red-600'}`}>{uploadMsg.text}</span>
          )}
          <label className="flex items-center gap-2 px-4 py-2 bg-blue-600 text-white text-sm rounded-lg hover:bg-blue-700 cursor-pointer">
            {uploading ? <Loader2 size={16} className="animate-spin" /> : <Upload size={16} />}
            Upload Binary
            <input
              ref={fileRef}
              type="file"
              accept=".tgz,.tar.gz"
              className="hidden"
              onChange={handleUpload}
              disabled={uploading}
            />
          </label>
        </div>
      </div>

      {loading ? (
        <div className="text-center py-12 text-gray-400">Loading versions...</div>
      ) : versions.length === 0 ? (
        <div className="text-center py-12">
          <Package size={48} className="mx-auto text-gray-300 mb-3" />
          <p className="text-gray-500">No Kafka versions found.</p>
          <p className="text-sm text-gray-400 mt-1">Upload a .tgz binary or add entries to version_catalog.json</p>
        </div>
      ) : (
        <div className="space-y-3">
          {versions.map(ver => {
            const isExpanded = expanded === ver.version;
            return (
              <div key={ver.version} className="bg-white border rounded-xl overflow-hidden">
                <button
                  onClick={() => setExpanded(isExpanded ? null : ver.version)}
                  className="w-full flex items-center gap-4 px-5 py-4 text-left hover:bg-gray-50 transition-colors"
                >
                  <div className="flex-1 min-w-0">
                    <div className="flex items-center gap-3">
                      <span className="text-lg font-semibold text-gray-900">
                        Kafka {ver.version}
                      </span>
                      {ver.available ? (
                        <span className="flex items-center gap-1 text-xs font-medium text-green-700 bg-green-50 px-2 py-0.5 rounded-full">
                          <CheckCircle size={12} /> Available
                        </span>
                      ) : (
                        <span className="flex items-center gap-1 text-xs font-medium text-gray-500 bg-gray-100 px-2 py-0.5 rounded-full">
                          <XCircle size={12} /> Not Downloaded
                        </span>
                      )}
                    </div>
                    <div className="flex items-center gap-4 mt-1 text-xs text-gray-500">
                      <span>Scala {ver.scala_version}</span>
                      {ver.release_date && <span>Released {ver.release_date}</span>}
                      {ver.available && <span>{ver.size_mb} MB</span>}
                      <span className="font-mono text-gray-400">{ver.filename}</span>
                    </div>
                  </div>
                  {isExpanded ? <ChevronUp size={18} className="text-gray-400" /> : <ChevronDown size={18} className="text-gray-400" />}
                </button>

                {isExpanded && (
                  <div className="px-5 pb-5 border-t bg-gray-50 space-y-4 pt-4">
                    {ver.features && ver.features.length > 0 && (
                      <div>
                        <h4 className="flex items-center gap-2 text-sm font-semibold text-gray-700 mb-2">
                          <Sparkles size={14} className="text-blue-500" /> Features
                        </h4>
                        <ul className="list-disc list-inside text-sm text-gray-600 space-y-1 ml-1">
                          {ver.features.map((f, i) => <li key={i}>{f}</li>)}
                        </ul>
                      </div>
                    )}

                    {ver.security_fixes && ver.security_fixes.length > 0 && (
                      <div>
                        <h4 className="flex items-center gap-2 text-sm font-semibold text-gray-700 mb-2">
                          <Shield size={14} className="text-red-500" /> Security Fixes
                        </h4>
                        <ul className="list-disc list-inside text-sm text-gray-600 space-y-1 ml-1">
                          {ver.security_fixes.map((f, i) => <li key={i}>{f}</li>)}
                        </ul>
                      </div>
                    )}

                    {ver.upgrade_notes && (
                      <div>
                        <h4 className="flex items-center gap-2 text-sm font-semibold text-gray-700 mb-2">
                          <ArrowUpCircle size={14} className="text-purple-500" /> Upgrade Notes
                        </h4>
                        <p className="text-sm text-gray-600 ml-1">{ver.upgrade_notes}</p>
                      </div>
                    )}

                    {!ver.features && !ver.security_fixes && !ver.upgrade_notes && (
                      <p className="text-sm text-gray-400 italic">
                        No additional metadata available for this version.
                      </p>
                    )}
                  </div>
                )}
              </div>
            );
          })}
        </div>
      )}
    </div>
  );
}
