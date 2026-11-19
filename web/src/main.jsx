import { useCallback, useEffect, useState } from "react";
import { createRoot } from "react-dom/client";
import {
  ThemeProvider,
  ToastProvider,
  HoverCardProvider,
  useTheme,
  isDarkTheme,
  Icon,
  IconButton,
  Input,
  Button,
  Alert,
} from "@intetech/ui-kit";
import "@intetech/ui-kit/styles.css";
import "@intetech/ui-kit/fonts.css";
import "./style.css";
import { callApi, useResource } from "./api.js";
import { emptyFilters, showActor } from "./model.js";
import { Busy, Failure } from "./common.jsx";
import { Registry } from "./registry.jsx";
import { EventCard } from "./card.jsx";
import { TypeCatalog, TypeDetails } from "./type-catalog.jsx";
import { TypeEditor, EditTypePage } from "./type-editor.jsx";

const sessionKey = "events.api-token";
function Header({ logout, actor }) {
  const { theme, toggleTheme } = useTheme();
  return (
    <header className="app-bar">
      <div className="bar-content">
        <a href="#/" className="brand">
          <span className="brand-mark">
            <Icon name="layers" size={20} />
          </span>
          Сервис событий
        </a>
        <div className="actions">
          {actor && <span className="session-actor">{showActor(actor.kind, actor.id)}</span>}
          <IconButton
            aria-label="Сменить тему"
            title="Сменить тему"
            name={isDarkTheme(theme) ? "sun" : "moon"}
            onClick={(e) => toggleTheme(e)}
          />
          {logout && (
            <Button variant="ghost" icon="log-out" onClick={logout}>
              Выйти
            </Button>
          )}
        </div>
      </div>
    </header>
  );
}
function Login({ connect, message }) {
  const [value, setValue] = useState("");
  function submit(e) {
    e.preventDefault();
    connect(value.trim());
  }
  return (
    <main className="login">
      <form className="surface login-form" onSubmit={submit}>
        <span className="section-icon">
          <Icon name="key-round" size={22} />
        </span>
        <h1>Вход в журнал событий</h1>
        <Input
          label="Токен доступа"
          type="password"
          value={value}
          autoComplete="off"
          autoFocus
          block
          onChange={(e) => setValue(e.target.value)}
          helper="Введите выданный вам токен."
        />
        {message && <Alert variant="danger" title={message} role="alert" />}
        <Button type="submit" disabled={!value.trim()}>
          Открыть журнал
        </Button>
      </form>
    </main>
  );
}
function Workspace({ api, canReview }) {
  const [route, setRoute] = useState(() => location.hash.slice(1) || "/");
  const [filters, setFilters] = useState(emptyFilters);
  const catalog = useResource(api, "/event-types");
  useEffect(() => {
    const fn = () => setRoute(location.hash.slice(1) || "/");
    window.addEventListener("hashchange", fn);
    return () => window.removeEventListener("hashchange", fn);
  }, []);
  const [path, query] = route.split("?");
  const match = /^\/events\/(new|[1-9]\d*)$/.exec(path);
  const typeDetails = /^\/types\/([1-9]\d*)(\/edit)?$/.exec(path);
  const typeId = new URLSearchParams(query).get("type");
  const catalogPage = path === "/types" || path === "/types/new" || !!typeDetails;
  let title = "Журнал событий";
  if (match) title = match[1] === "new" ? "Новое событие" : "Событие №" + match[1];
  if (catalogPage) title = path === "/types/new" ? "Новый тип события" : "Типы событий";
  useEffect(() => {
    document.title = title + " · Скважины";
  }, [title]);
  if (catalog.error)
    return (
      <main>
        <Failure error={catalog.error} retry={catalog.retry} />
      </main>
    );
  if (!catalog.data)
    return (
      <main>
        <Busy />
      </main>
    );
  function typeSaved(id) {
    location.hash = "/types/" + id;
    catalog.retry();
  }
  let screen;
  if (path === "/types/new") screen = <TypeEditor api={api} onSaved={typeSaved} />;
  else if (typeDetails?.[2]) screen = <EditTypePage api={api} id={typeDetails[1]} onSaved={typeSaved} />;
  else if (typeDetails) screen = <TypeDetails api={api} id={typeDetails[1]} />;
  else if (path === "/types") screen = <TypeCatalog types={catalog.data} />;
  else if (match)
    screen = <EventCard key={route} id={match[1]} initialType={typeId} types={catalog.data} api={api} canReview={canReview} />;
  else screen = <Registry api={api} types={catalog.data} filters={filters} apply={setFilters} />;
  return <main>{screen}</main>;
}
function App() {
  const [token, setToken] = useState(() => sessionStorage.getItem(sessionKey) || "");
  const [message, setMessage] = useState("");
  const logout = useCallback(() => {
    sessionStorage.removeItem(sessionKey);
    setToken("");
    setMessage("");
    location.hash = "/";
  }, []);
  const api = useCallback(
    async (path, options) => {
      try {
        return await callApi(token, path, options);
      } catch (err) {
        if (err.status === 401 && sessionStorage.getItem(sessionKey) === token) {
          logout();
          setMessage(err.message);
        }
        throw err;
      }
    },
    [token, logout],
  );
  function connect(value) {
    sessionStorage.setItem(sessionKey, value);
    setToken(value);
    setMessage("");
  }
  if (token) return <SignedIn key={token} api={api} logout={logout} />;
  return <><Header /><Login connect={connect} message={message} /></>;
}

function SignedIn({ api, logout }) {
  const session = useResource(api, "/me");
  return (
    <>
      <Header logout={logout} actor={session.data} />
      {session.error ? <main><Failure error={session.error} retry={session.retry} /></main>
        : session.data ? <Workspace api={api} canReview={session.data.can_review} /> : <main><Busy /></main>}
    </>
  );
}
createRoot(document.getElementById("root")).render(
  <ThemeProvider>
    <ToastProvider>
      <HoverCardProvider>
        <App />
      </HoverCardProvider>
    </ToastProvider>
  </ThemeProvider>,
);
