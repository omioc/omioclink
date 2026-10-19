/**
 * musicfree/storage 的等价实现。
 *
 * MusicFree 把插件键值存在一个全局 JSON 里；这里按插件隔离（Dart 侧用
 * `<插件 hash>/<key>` 落盘），但对外 API 完全一致：setItem/getItem/removeItem
 * 都是 Promise。getItem 直接读内存快照，setItem/removeItem 通过桥落盘。
 */
export function createStorage(pluginKey, snapshot) {
  const memory = Object.assign(Object.create(null), snapshot || {});
  const persist = (action, key, value) => {
    try {
      sendMessage(
        'mf.storage',
        JSON.stringify({ plugin: pluginKey, action, key, value: value ?? null }),
      );
    } catch (e) {
      // 落盘失败不影响插件本身（Dart 侧会记日志）
    }
  };
  return {
    async setItem(key, value) {
      const text = typeof value === 'string' ? value : String(value);
      memory[String(key)] = text;
      persist('set', String(key), text);
      return undefined;
    },
    async getItem(key) {
      const found = memory[String(key)];
      return found === undefined ? null : found;
    },
    async removeItem(key) {
      delete memory[String(key)];
      persist('delete', String(key), null);
      return undefined;
    },
  };
}
