import { Outlet } from 'react-router-dom';
import Sidebar from './Sidebar';

export default function Shell() {
  return (
    <div className="flex min-h-screen bg-gray-50">
      <div className="sticky top-0 h-screen flex-shrink-0">
        <Sidebar />
      </div>
      <main className="flex-1 overflow-auto">
        <div className="max-w-7xl mx-auto p-8">
          <Outlet />
        </div>
      </main>
    </div>
  );
}
