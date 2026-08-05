import { createBrowserRouter } from 'react-router-dom';

// TODO: 실제 화면이 준비되면 각 라우트에 연결한다. 현재는 껍데기만 둔다.
function ComingSoon() {
  return (
    <div style={{ padding: 24 }}>
      <h1>PlanFlow</h1>
      <p>Coming soon.</p>
    </div>
  );
}

export const router = createBrowserRouter([
  {
    path: '/',
    element: <ComingSoon />,
  },
]);
