import { WASI, File, OpenFile, ConsoleStdout } from '@bjorn3/browser_wasi_shim';
import { readFile } from 'node:fs/promises';
import { spawnSync } from 'node:child_process';
import { pathToFileURL } from 'node:url';
import { resolve } from 'node:path';
import assert from 'node:assert/strict';
const base=resolve('public/runtime');
const {default:imports}=await import(pathToFileURL(resolve(base,'workbench.js')).href);
const exports={};
const wasi=new WASI([],[],[new OpenFile(new File([])),ConsoleStdout.lineBuffered(console.log),ConsoleStdout.lineBuffered(console.error)]);
const module=await WebAssembly.compile(await readFile(resolve(base,'workbench.wasm')));
const instance=await WebAssembly.instantiate(module,{wasi_snapshot_preview1:wasi.wasiImport,ghc_wasm_jsffi:imports(exports)});
Object.assign(exports,instance.exports);wasi.initialize(instance);
const source=await readFile('../examples/school.ontology','utf8');
const query=await readFile('../examples/school.osql','utf8');
const cases=[{operation:'compile',root:'School',source},{operation:'query',root:'School',source,query},
 {operation:'query',root:'School',source,query:'9007199254740993.123456789'},
 {operation:'query',root:'School',source,query:'"héllo 😀"'},
 {operation:'query',root:'School',source,query:'root.invalid'},
 {operation:'compile',root:'School',source:'type School = {broken: Ref<Missing>[];};'}];
for (const input of cases){
 const text=JSON.stringify(input);
 const native=spawnSync(process.env.NATIVE_WORKBENCH_RUNTIME,[],{input:text,encoding:'utf8'});
 assert.equal(native.status,0,native.stderr);
 const actual=await exports.workbench_run(text);
 assert.deepEqual(JSON.parse(actual),JSON.parse(native.stdout));
}
console.log(`All ${cases.length} native/WASM parity cases passed.`);
