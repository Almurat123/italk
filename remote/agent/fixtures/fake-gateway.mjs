// A stand-in for iTalk's gateway for the Swift loopback tests: starts the scripted gateway from the Node test helpers and prints its URL.
// The "model" answers by what the last request says: WRITE:<path> → a write_file call, SLOW → a slow answer, anything else → a greeting.
import { fakeGateway } from '../test/helpers.mjs';

const gateway = await fakeGateway((body) => {
  const prompt = [...body.messages].reverse().find(m => m.role === 'user')?.content ?? '';
  const tool = body.messages.filter(m => m.role === 'tool').at(-1);
  if (tool) return { parts: [{ text: `Tool said: ${tool.content.slice(0, 80)}` }] };
  if (prompt.includes('ASK')) return { parts: [{ tool: { id: 't1', name: 'todo', args: { items: [{ text: 'Ask the person', status: 'in_progress' }, { text: 'Report', status: 'pending' }] } } }, { tool: { id: 'q1', index: 1, name: 'clarify', args: { question: 'Which folder?', choices: ['Downloads', 'Desktop'] } } }] };
  if (prompt.startsWith('WRITE:')) return { parts: [{ tool: { id: 'w1', name: 'write_file', args: { path: prompt.slice(6), content: 'written by the agent\n' } } }] };
  if (prompt.includes('SLOW')) return { parts: [{ text: 'part1 ' }, { delayMs: 700 }, { text: 'part2 ' }, { delayMs: 400 }, { text: 'part12' }] };
  return { parts: [{ reasoning: 'thinking about the greeting' }, { text: 'Hello from the Mac.' }] };
});
console.log(JSON.stringify({ url: gateway.url }));
setInterval(() => {}, 1 << 30);
