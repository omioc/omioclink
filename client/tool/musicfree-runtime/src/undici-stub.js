// cheerio 的 fromURL 依赖 undici（Node 专有），QuickJS 里用不到：构建时替换成空实现。
export const fetch = () => Promise.reject(new Error('undici.fetch 不可用'));
export const Agent = function Agent() {};
export default { fetch, Agent };