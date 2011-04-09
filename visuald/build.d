// This file is part of Visual D
//
// Visual D integrates the D programming language into Visual Studio
// Copyright (c) 2010 by Rainer Schuetze, All Rights Reserved
//
// License for redistribution is given by the Artistic License 2.0
// see file LICENSE for further details

module visuald.build;

import visuald.windows;
import std.c.stdlib;
import std.windows.charset;
import std.utf;
import std.string;
import std.regexp;
import std.file;
import std.path;
import std.conv;
import std.math;
import std.array;
import std.exception;
import core.thread;
import core.stdc.time;
import core.stdc.string;

import sdk.vsi.vsshell;
import sdk.vsi.vsshell80;
import sdk.vsi.vsshell90;

import visuald.comutil;
import visuald.chiernode;
import visuald.dproject;
import visuald.hierutil;
import visuald.hierarchy;
import visuald.fileutil;
import visuald.stringutil;
import visuald.config;
import visuald.dpackage;

// threaded builds cause Visual Studio to close the solution
// version = threadedBuild;
// version = taskedBuild;

version(taskedBuild)
{
	import stdext.parallelism;
}

// builder thread class
class CBuilderThread // : public CVsThread<CMyProjBuildableCfg>
{
public:
	this()
	{
	}

	~this()
	{
	}

	void Dispose()
	{
		m_pIVsOutputWindowPane = release(m_pIVsOutputWindowPane);
		m_srpIVsLaunchPadFactory = release(m_srpIVsLaunchPadFactory);
		m_pIVsStatusbar = release(m_pIVsStatusbar);
	}

	enum Operation
	{
		eIdle,
		eBuild,
		eRebuild,
		eCheckUpToDate,
		eClean,
	};

	HRESULT Start(Config cfg, Operation op, IVsOutputWindowPane pIVsOutputWindowPane)
	{
		m_op = op;
		mConfig = cfg;

		m_pIVsOutputWindowPane = release(m_pIVsOutputWindowPane);
		m_pIVsOutputWindowPane = addref(pIVsOutputWindowPane);

		// get a pointer to IVsLaunchPadFactory
		if (!m_srpIVsLaunchPadFactory)
		{
			m_srpIVsLaunchPadFactory = queryService!(IVsLaunchPadFactory);
			if (!m_srpIVsLaunchPadFactory)
				return E_FAIL;
		}
		// Note that the QueryService for SID_SVsStatusbar will fail during command line build
		if(!m_pIVsStatusbar)
			m_pIVsStatusbar = queryService!(IVsStatusbar);

		mSuccess = true;

		if(op == Operation.eCheckUpToDate)
			ThreadMain(); // synchronous handling needed
		else
		{
version(taskedBuild)
{
			auto task = task((CBuilderThread t) { t.ThreadMain(); }, this);
			taskPool.put(task);
}
else version(threadedBuild)
{
			mThread = new Thread(&ThreadMain);
			mThread.start();
}
else
			ThreadMain();
		}

		//return super::Start(pCMyProjBuildableCfg);
		return mSuccess ? S_OK : S_FALSE;
	}

	void Stop(BOOL fSync)
	{
		m_fStopBuild = TRUE;
	}

	void QueryStatus(BOOL *pfDone)
	{
		if(pfDone)
			*pfDone = (m_op == Operation.eIdle);
	}

	void ThreadMain()
	{
		BOOL fContinue = TRUE;
		BOOL fSuccessfulBuild = FALSE; // set up for Fire_BuildEnd() later on.

		scope(exit)
		{
			version(threadedBuild)
				mThread = null;
			m_op = Operation.eIdle;
		}
		m_fStopBuild = false;
		Fire_BuildBegin(fContinue);

		switch (m_op)
		{
		default:
			assert(false);
			break;

		case Operation.eBuild:
			fSuccessfulBuild = DoBuild();
			break;

		case Operation.eRebuild:
			fSuccessfulBuild = DoClean();
			if(fSuccessfulBuild)
				fSuccessfulBuild = DoBuild();
			break;

		case Operation.eCheckUpToDate:
			fSuccessfulBuild = DoCheckIsUpToDate();
			break;

		case Operation.eClean:
			fSuccessfulBuild = DoClean();
			break;
		}

		Fire_BuildEnd(fSuccessfulBuild);
		mSuccess = fSuccessfulBuild != 0;
	}

	bool isStopped() const { return m_fStopBuild != 0; }
	
	bool doCustomBuilds()
	{
		string workdir = mConfig.GetProjectDir();

		CHierNode node = searchNode(mConfig.GetProjectNode(), 
			delegate (CHierNode n) { 
				if(CFileNode file = cast(CFileNode) n)
				{
					if(isStopped())
						return true;
					if(!mConfig.isUptodate(file))
					{
						string cmdline = mConfig.GetCompileCommand(file);
						if(cmdline.length)
						{
							string outfile = mConfig.GetOutputFile(file);
							string cmdfile = makeFilenameAbsolute(outfile ~ "." ~ kCmdLogFileExtension, workdir);
							HRESULT hr = RunCustomBuildBatchFile(outfile, cmdfile, cmdline, m_pIVsOutputWindowPane, this);
							if (hr != S_OK)
								return true; // stop compiling
						}
					}
				}
				return false;
			});

		return node is null;
	}

	bool DoBuild()
	{
		beginLog();
		HRESULT hr = S_FALSE;
		
		try
		{
			string target = mConfig.GetTargetPath();
			string msg = "Building " ~ target ~ "...\n";
			if(m_pIVsOutputWindowPane)
			{
				ScopedBSTR bstrMsg = ScopedBSTR(msg);
				m_pIVsOutputWindowPane.OutputString(bstrMsg);
			}

			string workdir = mConfig.GetProjectDir();
			string outdir = makeFilenameAbsolute(mConfig.GetOutDir(), workdir);
			if(!exists(outdir))
				mkdirRecurse(outdir);
			string intermediatedir = makeFilenameAbsolute(mConfig.GetIntermediateDir(), workdir);
			if(!exists(intermediatedir))
				mkdirRecurse(intermediatedir);
			
			string modules_ddoc;
			if(mConfig.getModulesDDocCommandLine([], modules_ddoc))
			{
				modules_ddoc = unquoteArgument(modules_ddoc);
				modules_ddoc = mConfig.GetProjectOptions().replaceEnvironment(modules_ddoc, mConfig);
				string modpath = dirname(modules_ddoc);
				modpath = makeFilenameAbsolute(modpath, workdir);
				if(!exists(modpath))
					mkdirRecurse(modpath);
			}
			
			if(!doCustomBuilds())
				return false;

			string cmdline = mConfig.getCommandLine();
			string cmdfile = makeFilenameAbsolute(mConfig.GetCommandLinePath(), workdir);
			hr = RunCustomBuildBatchFile(target, cmdfile, cmdline, m_pIVsOutputWindowPane, this);
			return (hr == S_OK);
		}
		catch(FileException fe)
		{
			OutputText("Error setting up build: " ~ fe.msg);
			return false;
		}
		finally
		{
			endLog(hr == S_OK);
		}
	}

	bool customFilesUpToDate()
	{
		CHierNode node = searchNode(mConfig.GetProjectNode(), 
			delegate (CHierNode n) 
			{
				if(isStopped())
					return true;
				if(CFileNode file = cast(CFileNode) n)
				{
					if(!mConfig.isUptodate(file))
						return true;
				}
				return false;
			});
		
		return node is null;
	}

	bool DoCheckIsUpToDate()
	{
		clearCachedFileTimes();
		scope(exit) clearCachedFileTimes();
		
		if(!customFilesUpToDate())
			return false;

		string workdir = mConfig.GetProjectDir();
		string cmdfile = makeFilenameAbsolute(mConfig.GetCommandLinePath(), workdir);

		string cmdline = mConfig.getCommandLine();
		if(!compareCommandFile(cmdfile, cmdline))
			return false;

		string target = makeFilenameAbsolute(mConfig.GetTargetPath(), workdir);
		long targettm = getOldestFileTime( [ target ] );
		
		string deppath = makeFilenameAbsolute(mConfig.GetDependenciesPath(), workdir);
		if(!std.file.exists(deppath))
			return false;
		string[] files;
		if(!getFilenamesFromDepFile(deppath, files))
			return false;
		string[] libs = mConfig.getLibsFromDependentProjects();
		files ~= libs;
		makeFilenamesAbsolute(files, workdir);
		long sourcetm = getNewestFileTime(files);

		return targettm > sourcetm;
	}

	bool DoClean()
	{
		string[] files = mConfig.GetBuildFiles();
		foreach(string file; files)
		{
			try
			{
				if(indexOf(file,'*') >= 0 || indexOf(file,'?') >= 0)
				{
					string dir = dirname(file);
					string pattern = basename(file);
					foreach(string f; dirEntries(dir, SpanMode.shallow))
						if(fnmatch(f, pattern))
							std.file.remove(f);
				}
				else if(std.file.exists(file))
					std.file.remove(file);
			}
			catch(FileException e)
			{
				OutputText("cannot delete " ~ file ~ ":" ~ e.msg);
			}
		}
		return true;
	}
	
	void OutputText(string msg)
	{
		wchar* wmsg = _toUTF16z(msg);
		if (m_pIVsStatusbar)
		{
			m_pIVsStatusbar.SetText(wmsg);
		}
		if (m_pIVsOutputWindowPane)
		{
			m_pIVsOutputWindowPane.OutputString(wmsg);
			m_pIVsOutputWindowPane.OutputString(cast(wchar*)"\n"w.ptr);
		}
	}
/+
	void InternalTick(ref BOOL rfContine);
+/

	void Fire_Tick(ref BOOL rfContinue) 
	{
		rfContinue = mConfig.FFireTick() && !m_fStopBuild;
	}

	void Fire_BuildBegin(ref BOOL rfContinue)
	{
		mConfig.FFireBuildBegin(rfContinue);
	}

	void Fire_BuildEnd(BOOL fSuccess)
	{
		mConfig.FFireBuildEnd(fSuccess);
	}

	void beginLog()
	{
		mStartBuildTime = time(null);
		
		mBuildLog = `<html><head><META HTTP-EQUIV="Content-Type" content="text/html">
</head><body><pre>
<table width=100% bgcolor=#CFCFE5><tr><td>
	<font face=arial size=+3>Build Log</font>
</table>
`;
	}

	void addCommandLog(string target, string cmd, string output)
	{
		if(!mCreateLog)
			return;
		
		mBuildLog ~= "<table width=100% bgcolor=#DFDFE5><tr><td><font face=arial size=+2>\n";
		mBuildLog ~= xml.encode("Building " ~ target);
		mBuildLog ~= "\n</font></table>\n";
		
		mBuildLog ~= "<table width=100% bgcolor=#EFEFE5><tr><td><font face=arial size=+1>\n";
		mBuildLog ~= "Command Line";
		mBuildLog ~= "\n</font></table>\n";
		
		mBuildLog ~= xml.encode(cmd);

		mBuildLog ~= "<table width=100% bgcolor=#EFEFE5><tr><td><font face=arial size=+1>\n";
		mBuildLog ~= "Output";
		mBuildLog ~= "\n</font></table>\n";
		
		mBuildLog ~= xml.encode(output) ~ "\n";
	}
	
	void endLog(bool success)
	{
		if(!mCreateLog)
			return;
		
		mBuildLog ~= "</body></html>";

		string workdir = mConfig.GetProjectDir();
		string intdir = makeFilenameAbsolute(mConfig.GetIntermediateDir(), workdir);
		string logfile = normalizeDir(intdir) ~ "buildlog.html";
		try
		{
			std.file.write(logfile, mBuildLog);
			if(!success)
				OutputText("Details saved as \"file://" ~ logfile ~ "\"");
		}
		catch(FileException e)
		{
			OutputText("cannot write " ~ logfile ~ ":" ~ e.msg);
		}

		if(Package.GetGlobalOptions().timeBuilds)
		{
			time_t now = time(null);
			double duration = difftime(now, mStartBuildTime);
			if(duration >= 60)
			{
				int min = cast(int) floor(duration / 60);
				int sec = cast(int) floor(duration - 60 * min);
				string tm = format("%d:%02d", min, sec);
				OutputText("Build time: " ~ to!string(min) ~ ":" ~ to!string(sec) ~ " min");
			}
			else
				OutputText("Build time: " ~ to!string(duration) ~ " s");
		}
	}
	
/+
	virtual HRESULT PrepareInStartingThread(CMyProjBuildableCfg *pCMyProjBuildableCfg);
	virtual HRESULT InnerThreadMain(CMyProjBuildableCfg *pBuildableCfg);

	virtual void ReleaseThreadHandle();

+/

	Config mConfig;
	IVsLaunchPadFactory m_srpIVsLaunchPadFactory;

	IStream m_pIStream_IVsOutputWindowPane;
	IVsOutputWindowPane m_pIVsOutputWindowPane;

	IStream m_pIStream_IVsStatusbar;
	IVsStatusbar m_pIVsStatusbar;

	BOOL m_fIsUpToDate;
	Operation m_op;

	BOOL m_fStopBuild;
	HANDLE m_hEventStartSync;

	time_t mStartBuildTime;
	
	version(threadedBuild)
		Thread mThread; // keep a reference to the thread to avoid it from being collected
	bool mSuccess = false;
	bool mCreateLog = true;
	string mBuildLog;
};

class CLaunchPadEvents : DComObject, IVsLaunchPadEvents
{
	this(CBuilderThread builder)
	{
		m_pBuilder = builder;
	}

	override HRESULT QueryInterface(in IID* riid, void** pvObject)
	{
		if(queryInterface!(IVsLaunchPadEvents) (this, riid, pvObject))
			return S_OK;
		return super.QueryInterface(riid, pvObject);
	}

	// IVsLaunchPadEvents
	override HRESULT Tick(/* [out] */ BOOL * pfCancel)
	{
		BOOL fContinue = TRUE;
		m_pBuilder.Fire_Tick(fContinue);
		*pfCancel = !fContinue;
		return S_OK;
	}

public:
	CBuilderThread m_pBuilder;
};

class CLaunchPadOutputParser : DComObject, IVsLaunchPadOutputParser 
{
	this(CBuilderThread builder)
	{
		mProjectDir = builder.mConfig.GetProjectDir();
	}
 
	override HRESULT QueryInterface(in IID* riid, void** pvObject)
	{
		if(queryInterface!(IVsLaunchPadOutputParser) (this, riid, pvObject))
			return S_OK;
		return super.QueryInterface(riid, pvObject);
	}

	override HRESULT ParseOutputStringForInfo(
		in LPCOLESTR pszOutputString,   // one line of output text
		/+[out, optional]+/ BSTR *pbstrFilename,        // fully-qualified file name for task list item (may be NULL)
		/+[out, optional]+/ ULONG *pnLineNum,           // file line number for task list item (may be NULL)
		/+[out, optional]+/ ULONG *pnPriority,          // priority for task list item (may be NULL)
		/+[out, optional]+/ BSTR *pbstrTaskItemText,    // description text for task list item (may be NULL)
		/+[out, optional]+/ BSTR *pbstrHelpKeyword)
	{
		string line = to_string(pszOutputString);
		uint nPriority, nLineNum;
		string filename, taskItemText;
		
		if(!parseOutputStringForTaskItem(line, nPriority, filename, nLineNum, taskItemText))
			return S_FALSE;
		
		filename = makeFilenameAbsolute(filename, mProjectDir);
		if(pnPriority)
			*pnPriority = nPriority;
		if(pnLineNum)
			*pnLineNum = nLineNum - 1;
		if(pbstrFilename)
			*pbstrFilename = allocBSTR(filename);
		if(pbstrTaskItemText)
			*pbstrTaskItemText = allocBSTR(taskItemText);
		return S_OK;
	}

	string mProjectDir;
}


// Runs the build commands, writing cmdfile if successful
HRESULT RunCustomBuildBatchFile(string              target,
                                string              buildfile,
                                string              cmdline, 
                                IVsOutputWindowPane pIVsOutputWindowPane, 
                                CBuilderThread      pBuilder)
{
	if (cmdline.length == 0)
		return S_OK;
	HRESULT hr = S_OK;

	// get the project root directory.
	string strProjectDir = pBuilder.mConfig.GetProjectDir();
	string batchFileText = insertCr(cmdline);
	string output;
	
	string cmdfile = buildfile ~ ".cmd";
	
	assert(pBuilder.m_srpIVsLaunchPadFactory);
	ComPtr!(IVsLaunchPad) srpIVsLaunchPad;
	hr = pBuilder.m_srpIVsLaunchPadFactory.CreateLaunchPad(&srpIVsLaunchPad.ptr);
	if(FAILED(hr))
	{
		output = format("internal error: IVsLaunchPadFactory.CreateLaunchPad failed with rc=%x", hr);
		goto failure;
	}
	assert(srpIVsLaunchPad.ptr);

	CLaunchPadEvents pLaunchPadEvents = new CLaunchPadEvents(pBuilder);

	BSTR bstrOutput;
version(none)
{
	hr = srpIVsLaunchPad.ExecBatchScript(
		/* [in] LPCOLESTR pszBatchFileContents         */ _toUTF16z(batchFileText),
		/* [in] LPCOLESTR pszWorkingDir                */ _toUTF16z(strProjectDir),      // may be NULL, passed on to CreateProcess (wee Win32 API for details)
		/* [in] LAUNCHPAD_FLAGS lpf                    */ LPF_PipeStdoutToOutputWindow,
		/* [in] IVsOutputWindowPane *pOutputWindowPane */ pIVsOutputWindowPane, // if LPF_PipeStdoutToOutputWindow, which pane in the output window should the output be piped to
		/* [in] ULONG nTaskItemCategory                */ 0, // if LPF_PipeStdoutToTaskList is specified
		/* [in] ULONG nTaskItemBitmap                  */ 0, // if LPF_PipeStdoutToTaskList is specified
		/* [in] LPCOLESTR pszTaskListSubcategory       */ null, // if LPF_PipeStdoutToTaskList is specified
		/* [in] IVsLaunchPadEvents *pVsLaunchPadEvents */ pLaunchPadEvents,
		/* [out] BSTR *pbstrOutput                     */ &bstrOutput); // all output generated (may be NULL)

	if(FAILED(hr))
	{
		output = format("internal error: IVsLaunchPad.ptr.ExecBatchScript failed with rc=%x", hr);
		goto failure;
	}
} else {
	try
	{
		int cp = GetKBCodePage();
		const(char)*p = toMBSz(batchFileText, cp);
		int plen = strlen(p);
		std.file.write(cmdfile, p[0..plen]);
	}
	catch(FileException e)
	{
		output = format("internal error: cannot write file " ~ cmdfile);
		hr = S_FALSE;
	}
	DWORD result;
	if(IVsLaunchPad2 pad2 = qi_cast!IVsLaunchPad2(srpIVsLaunchPad))
	{
		CLaunchPadOutputParser pLaunchPadOutputParser = new CLaunchPadOutputParser(pBuilder);
		hr = pad2.ExecCommandEx(
			/* [in] LPCOLESTR pszApplicationName           */ _toUTF16z(getCmdPath()),
			/* [in] LPCOLESTR pszCommandLine               */ _toUTF16z("/Q /C " ~ quoteFilename(cmdfile)),
			/* [in] LPCOLESTR pszWorkingDir                */ _toUTF16z(strProjectDir),      // may be NULL, passed on to CreateProcess (wee Win32 API for details)
			/* [in] LAUNCHPAD_FLAGS lpf                    */ LPF_PipeStdoutToOutputWindow | LPF_PipeStdoutToTaskList,
			/* [in] IVsOutputWindowPane *pOutputWindowPane */ pIVsOutputWindowPane, // if LPF_PipeStdoutToOutputWindow, which pane in the output window should the output be piped to
			/* [in] ULONG nTaskItemCategory                */ CAT_BUILDCOMPILE, // if LPF_PipeStdoutToTaskList is specified
			/* [in] ULONG nTaskItemBitmap                  */ 0, // if LPF_PipeStdoutToTaskList is specified
			/* [in] LPCOLESTR pszTaskListSubcategory       */ null, // "Build"w.ptr, // if LPF_PipeStdoutToTaskList is specified
			/* [in] IVsLaunchPadEvents pVsLaunchPadEvents  */ pLaunchPadEvents,
			/* [in] IVsLaunchPadOutputParser pOutputParser */ pLaunchPadOutputParser,
			/* [out] DWORD *pdwProcessExitCode             */ &result,
			/* [out] BSTR *pbstrOutput                     */ &bstrOutput); // all output generated (may be NULL)
		release(pad2);
	}
	else
		hr = srpIVsLaunchPad.ExecCommand(
			/* [in] LPCOLESTR pszApplicationName           */ _toUTF16z(getCmdPath()),
			/* [in] LPCOLESTR pszCommandLine               */ _toUTF16z("/Q /C " ~ quoteFilename(cmdfile)),
			/* [in] LPCOLESTR pszWorkingDir                */ _toUTF16z(strProjectDir),      // may be NULL, passed on to CreateProcess (wee Win32 API for details)
			/* [in] LAUNCHPAD_FLAGS lpf                    */ LPF_PipeStdoutToOutputWindow | LPF_PipeStdoutToTaskList,
			/* [in] IVsOutputWindowPane *pOutputWindowPane */ pIVsOutputWindowPane, // if LPF_PipeStdoutToOutputWindow, which pane in the output window should the output be piped to
			/* [in] ULONG nTaskItemCategory                */ CAT_BUILDCOMPILE, // if LPF_PipeStdoutToTaskList is specified
			/* [in] ULONG nTaskItemBitmap                  */ 0, // if LPF_PipeStdoutToTaskList is specified
			/* [in] LPCOLESTR pszTaskListSubcategory       */ null, // "Build"w.ptr, // if LPF_PipeStdoutToTaskList is specified
			/* [in] IVsLaunchPadEvents *pVsLaunchPadEvents */ pLaunchPadEvents,
			/* [out] DWORD *pdwProcessExitCode             */ &result,
			/* [out] BSTR *pbstrOutput                     */ &bstrOutput); // all output generated (may be NULL)
		
	if(FAILED(hr))
	{
		output = format("internal error: IVsLaunchPad.ptr.ExecCommand failed with rc=%x", hr);
		goto failure;
	}
	else if(result != 0)
		hr = S_FALSE;
}
	// don't know how to get at the exit code, so check output string
	output = strip(detachBSTR(bstrOutput));
	if(hr == S_OK && _endsWith(output, "failed!"))
		hr = S_FALSE;

	// outputToErrorList(srpIVsLaunchPad, pBuilder, pIVsOutputWindowPane, output);

	if(hr == S_OK)
	{
		try
		{
			std.file.write(buildfile, cmdline);
		}
		catch(FileException e)
		{
			output = format("internal error: cannot write file " ~ buildfile);
			hr = S_FALSE;
		}
	}
failure:
	pBuilder.addCommandLog(target, cmdline, output);
	return hr;
}

HRESULT outputToErrorList(IVsLaunchPad pad, CBuilderThread pBuilder,
                          IVsOutputWindowPane outPane, string output)
{
	HRESULT hr;

	auto prj = _toUTF16z(pBuilder.mConfig.GetProjectPath());
	string[] lines = std.string.split(output, "\n");
	foreach(line; lines)
	{
		uint nPriority, nLineNum;
		string strFilename, strTaskItemText;
		
		if(parseOutputStringForTaskItem(line, nPriority, strFilename, nLineNum, strTaskItemText))
		{
			if(IVsOutputWindowPane2 pane2 = qi_cast!IVsOutputWindowPane2(outPane))
				hr = pane2.OutputTaskItemStringEx2(
							"."w.ptr,              // The text to write to the output window.
							nPriority,             // The priority: use TP_HIGH for errors.
							CAT_BUILDCOMPILE,      // Not used internally; pass NULL unless you want to use it for your own purposes.
							null,                  // Not used internally; pass NULL unless you want to use it for your own purposes.
							0,                     // Not used internally.
							_toUTF16z(strFilename),          // The file name for the Error List entry; may be NULL if no file is associated with the error.
							nLineNum,              // Zero-based line number in pszFilename.
							nLineNum,                     // Zero-based column in pszFilename.
							prj,                   // The unique name of the project for the Error List entry; may be NULL if no project is associated with the error.
							_toUTF16z(strTaskItemText),      // The text of the Error List entry.
							""w.ptr);              // in LPCOLESTR pszLookupKwd
			else // no project or column +/
				hr = outPane.OutputTaskItemStringEx(
							" "w.ptr,               // The text to write to the output window.
							nPriority,             // The priority: use TP_HIGH for errors.
							CAT_BUILDCOMPILE,      // Not used internally; pass NULL unless you want to use it for your own purposes.
							null,                  // Not used internally; pass NULL unless you want to use it for your own purposes.
							0,                     // Not used internally.
							_toUTF16z(strFilename),          // The file name for the Error List entry; may be NULL if no file is associated with the error.
							nLineNum,              // Zero-based line number in pszFilename.
							_toUTF16z(strTaskItemText),      // The text of the Error List entry.
							""w.ptr);              // in LPCOLESTR pszLookupKwd
		}
	}
	return hr;
}

bool parseOutputStringForTaskItem(string outputLine, out uint nPriority,
                                  out string filename, out uint nLineNum,
                                  out string itemText)
{
	outputLine = strip(outputLine);
	
	// DMD compile error
	static RegExp re1, re2, re3, re4;
	if(!re1)
		re1 = new RegExp(r"^(.*)\(([0-9]+)\):(.*)$");
	
	string[] match = re1.exec(outputLine);
	if(match.length == 4)
	{
		nPriority = TP_HIGH;
		filename = replace(match[1], "\\\\", "\\");
		string lineno = replace(match[2], "\\\\", "\\");
		nLineNum = to!uint(lineno);
		itemText = strip(match[3]);
		return true;
	}

	// link error
	if(!re2)
		re2 = new RegExp(r"^ *(Error *[0-9]+:.*)$");

	match = re2.exec(outputLine);
	if(match.length == 2)
	{
		nPriority = TP_HIGH;
		filename = "";
		nLineNum = 0;
		itemText = strip(match[1]);
		return true;
	}

	// link error with file name
	if(!re3)
		re3 = new RegExp(r"^(.*)\(([0-9]+)\) *: *(Error *[0-9]+:.*)$");

	match = re3.exec(outputLine);
	if(match.length == 4)
	{
		nPriority = TP_HIGH;
		filename = replace(match[1], "\\\\", "\\");
		string lineno = replace(match[2], "\\\\", "\\");
		nLineNum = to!uint(lineno);
		itemText = strip(match[3]);
		return true;
	}

	// link warning
	if(!re4)
		re4 = new RegExp(r"^ *(Warning *[0-9]+:.*)$");

	match = re4.exec(outputLine);
	if(match.length == 2)
	{
		nPriority = TP_NORMAL;
		filename = "";
		nLineNum = 0;
		itemText = strip(match[1]);
		return true;
	}

	return false;
}

unittest
{
	uint nPriority, nLineNum;
	string strFilename, strTaskItemText;
	bool rc = parseOutputStringForTaskItem("file.d(37): huhu", nPriority, strFilename, nLineNum, strTaskItemText);
	assert(rc);
	assert(strFilename == "file.d");
	assert(nLineNum == 37);
	assert(strTaskItemText == "huhu");
}

string unEscapeFilename(string file)
{
	int pos = indexOf(file, '\\');
	if(pos < 0)
		return file;

	char[] p;
	int start = 0;
	while(pos < file.length)
	{
		if(file[pos+1] == '(' || file[pos+1] == ')' || file[pos+1] == '\\')
		{
			p ~= file[start .. pos];
			start = pos + 1;
		}
		int nextpos = indexOf(file[pos + 1 .. $], '\\');
		if(nextpos < 0)
			break;
		pos += nextpos + 1;
	}
	p ~= file[start..$];
	return assumeUnique(p);
}

string re_match_dep = r"^[A-Za-z0-9_\.]+ *\((.*)\) : p[a-z]* : [A-Za-z0-9_\.]+ \((.*)\)$";

bool getFilenamesFromDepFile(string depfile, ref string[] files)
{
	int[string] aafiles;
	
	int cntValid = 0;
	try
	{
		string txt = cast(string)std.file.read(depfile);

version(slow)
{
		RegExp re = new RegExp(re_match_dep);
		string[] lines = splitlines(txt);
		foreach(line; lines)
		{
			string[] match = re.exec(line);
			if(match.length == 3)
			{
				string file1 = replace(match[1], "\\\\", "\\");
				string file2 = replace(match[2], "\\\\", "\\");
				aafiles[file1] = 1;
				aafiles[file2] = 1;
				cntValid++;
			}
		}
}
else
{
		uint pos = 0;
		uint openpos = 0;
		bool skipNext = false;
		while(pos < txt.length)
		{
			dchar ch = decode(txt, pos);
			if(skipNext)
			{
				skipNext = false;
				continue;
			}
			if(ch == '\\')
				skipNext = true;
			if(ch == '(')
				openpos = pos;
			else if(ch == ')' && openpos > 0)
			{
				// only check lines that import "object", these are written once per file
				const string kCheck = " : public : object ";
				if(pos + kCheck.length <= txt.length && txt[pos .. pos + kCheck.length] == kCheck)
				{
					string file = txt[openpos .. pos-1];
					file = unEscapeFilename(file);
					aafiles[file] = 1;
					openpos = 0;
					cntValid++;
				}
			}
			else if(ch == '\n')
				openpos = 0;
		}
				
}
	}
	catch(Exception e)
	{
		cntValid = 0;
		// file read error
	}

	files ~= aafiles.keys;
	files.sort; // for faster file access?
	return cntValid > 0;
}

version(slow)
unittest
{
	string line = r"std.file (c:\\dmd\\phobos\\std\\file.d) : public : std.utf (c:\\dmd\\phobos\\std\\utf.d)";

	RegExp re = new RegExp(re_match_dep);
	string[] match = re.exec(line);

	assert(match.length == 3);
	assert(match[0] == line);
	assert(match[1] == r"c:\\dmd\\phobos\\std\\file.d");
	assert(match[2] == r"c:\\dmd\\phobos\\std\\utf.d");

	line = r"std.file (c:\\dmd\\phobos\\std\\file.d) : public : std.utf (c:\\dmd\\phobos\\std\\utf.d):abc,def";
	match = re.exec(line);

	assert(match.length == 3);
	assert(match[0] == line);
	assert(match[1] == r"c:\\dmd\\phobos\\std\\file.d");
	assert(match[2] == r"c:\\dmd\\phobos\\std\\utf.d");
}

