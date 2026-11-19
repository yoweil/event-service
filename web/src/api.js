import { useCallback, useEffect, useState } from "react";
import { decode, encode } from "./model.js";

const messages = {
  400: "Проверьте введённые значения.",
  401: "Токен не принят. Введите токен сервера.",
  404: "Запись не найдена.",
  409: "Карточка изменилась с момента открытия.",
  413: "Файл превышает 20 МиБ.",
  422: "Значения не соответствуют настройкам типа.",
  503: "База занята. Попробуйте ещё раз.",
};
export async function callApi(token, path, { body, method = "GET", signal, responseType } = {}) {
  const jsonBody = body != null && !(body instanceof FormData);
  const response = await fetch(path, {
    method,
    signal,
    headers: {
      Authorization: "Bearer " + token,
      ...(jsonBody ? { "Content-Type": "application/json" } : {}),
    },
    body: jsonBody ? encode(body) : body,
  });
  if (!response.ok) {
    const detail = await response.json().catch(() => null);
    throw Object.assign(new Error(messages[response.status] ?? "Не удалось выполнить запрос."), {
      status: response.status,
      reason: detail?.error,
    });
  }
  return responseType === "blob" ? response.blob() : decode(await response.text());
}

export function useResource(api, path) {
  const [state, setState] = useState({});
  const [attempt, setAttempt] = useState(0);
  const retry = useCallback(() => setAttempt((n) => n + 1), []);
  useEffect(() => {
    if (!path) return;
    const ctl = new AbortController();
    api(path, { signal: ctl.signal })
      .then((data) => {
        if (!ctl.signal.aborted) setState({ path, attempt, data });
      })
      .catch((error) => {
        if (!ctl.signal.aborted) setState({ path, attempt, error });
      });
    return () => ctl.abort();
  }, [api, path, attempt]);
  return { ...(state.path === path && state.attempt === attempt ? state : { loading: !!path }), retry };
}
