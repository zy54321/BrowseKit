// BrowseKit.Shell — Win11 virtual desktop + dedicated Chrome window helpers.
// Windows PowerShell 5.1 loads this file with Add-Type. No extra runtime, no network.
//
// Virtual desktop layout: Windows 11 build >= 26100 (24H2 / 25H2 / 26H1).
// IVirtualDesktopManagerInternal IID {53F5CA0B-158F-4124-900C-057158060B27}
// Vtable matches the 24H2 contract: GetCount, MoveViewToDesktop, GetCurrentDesktop,
// GetDesktops, CreateDesktop, SwitchDesktop, RemoveDesktop.
// Window move prefers the documented IVirtualDesktopManager.
// Verified on this machine: Windows 11 26H1 Build 28000.3501.
// Callers must treat COM failures as recoverable.

using System;
using System.Collections.Generic;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Text;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;
using System.Windows.Forms;

namespace BrowseKit.Shell
{
    public sealed class VirtualDesktopException : Exception
    {
        public VirtualDesktopException(string message) : base(message) { }
        public VirtualDesktopException(string message, Exception inner) : base(message, inner) { }
    }

    public static class VirtualDesktopHost
    {
        public static int OsBuild()
        {
            return OsInfo.Build;
        }

        public static int OsUbr()
        {
            return OsInfo.Ubr;
        }

        public static string OsLabel()
        {
            return OsInfo.Build.ToString() + "." + OsInfo.Ubr.ToString();
        }

        public static int GetCount()
        {
            return Call<int>(delegate { return Engine.GetCount(); }, "读取虚拟桌面数量失败");
        }

        public static int GetCurrentIndex()
        {
            return Call<int>(delegate { return Engine.GetCurrentIndex(); }, "读取当前虚拟桌面失败");
        }

        public static string[] GetDesktopIds()
        {
            return Call<string[]>(delegate { return Engine.GetDesktopIds(); }, "枚举虚拟桌面失败");
        }

        public static bool IsWindowOnCurrentDesktop(long hwnd)
        {
            return Call<bool>(delegate { return Engine.IsOnCurrent(new IntPtr(hwnd)); }, "判断窗口所在桌面失败");
        }

        public static string GetWindowDesktopId(long hwnd)
        {
            return Call<string>(delegate { return Engine.GetWindowDesktopId(new IntPtr(hwnd)); }, "读取窗口桌面标识失败");
        }

        public static int GetWindowDesktopIndex(long hwnd)
        {
            return Call<int>(delegate { return Engine.GetWindowDesktopIndex(new IntPtr(hwnd)); }, "读取窗口桌面索引失败");
        }

        public static void MoveWindowToDesktop(long hwnd, int index)
        {
            Call<object>(delegate { Engine.MoveTo(new IntPtr(hwnd), index); return null; }, "移动窗口到虚拟桌面失败");
        }

        public static int EnsureDesktopCount(int minimum)
        {
            return Call<int>(delegate { return Engine.EnsureCount(minimum); }, "准备虚拟桌面失败");
        }

        public static void SwitchToIndex(int index)
        {
            Call<object>(delegate { Engine.SwitchTo(index); return null; }, "切换虚拟桌面失败");
        }

        public static void RemoveDesktopById(string desktopId)
        {
            Call<object>(delegate { Engine.RemoveById(desktopId); return null; }, "移除虚拟桌面失败");
        }

        private static T Call<T>(Func<T> func, string context)
        {
            try
            {
                return StaThread.Invoke<T>(func);
            }
            catch (VirtualDesktopException)
            {
                throw;
            }
            catch (Exception ex)
            {
                throw new VirtualDesktopException(context + "：" + ex.Message + "（Win11 Build " + OsInfo.Build.ToString() + "." + OsInfo.Ubr.ToString() + "）", ex);
            }
        }
    }

    public static class ChromeWindows
    {
        public static long FindMainWindow(int[] processIds)
        {
            return WindowEnum.FindMain(processIds);
        }

        public static string[] ListMainWindows()
        {
            return WindowEnum.ListMain();
        }
    }

    public static class WindowActivator
    {
        public static long ForegroundHwnd()
        {
            return Native.GetForegroundWindow().ToInt64();
        }

        public static bool RestoreAndForeground(long hwndValue)
        {
            IntPtr hwnd = new IntPtr(hwndValue);
            if (hwnd == IntPtr.Zero) return false;
            if (!Native.IsWindow(hwnd)) return false;
            if (Native.IsIconic(hwnd)) Native.ShowWindow(hwnd, Native.SwRestore);
            else Native.ShowWindow(hwnd, Native.SwShow);

            uint fgPid;
            IntPtr fg = Native.GetForegroundWindow();
            uint fgThread = 0;
            if (fg != IntPtr.Zero) fgThread = Native.GetWindowThreadProcessId(fg, out fgPid);
            uint targetPid;
            uint targetThread = Native.GetWindowThreadProcessId(hwnd, out targetPid);
            uint current = Native.GetCurrentThreadId();

            bool attachedFg = false;
            bool attachedTarget = false;
            if (fgThread != 0 && fgThread != current) attachedFg = Native.AttachThreadInput(current, fgThread, true);
            if (targetThread != 0 && targetThread != current) attachedTarget = Native.AttachThreadInput(current, targetThread, true);
            try
            {
                Native.BringWindowToTop(hwnd);
                Native.SetForegroundWindow(hwnd);
                if (Native.GetForegroundWindow() != hwnd)
                {
                    Native.keybd_event(Native.VkMenu, 0, 0, UIntPtr.Zero);
                    Native.SetForegroundWindow(hwnd);
                    Native.keybd_event(Native.VkMenu, 0, Native.KeyeventfKeyup, UIntPtr.Zero);
                }
            }
            finally
            {
                if (attachedTarget) Native.AttachThreadInput(current, targetThread, false);
                if (attachedFg) Native.AttachThreadInput(current, fgThread, false);
            }
            return Native.GetForegroundWindow() == hwnd;
        }
    }

    public static class HotkeyNative
    {
        public const int HotkeyId = 0xB162;

        public static string TryRegisterCtrlAltB(IntPtr hwnd)
        {
            if (hwnd == IntPtr.Zero) return "热键窗口句柄无效";
            if (Native.RegisterHotKey(hwnd, HotkeyId, Native.ModControl | Native.ModAlt | Native.ModNorepeat, Native.VkB)) return "";
            int first = Marshal.GetLastWin32Error();
            if (Native.RegisterHotKey(hwnd, HotkeyId, Native.ModControl | Native.ModAlt, Native.VkB)) return "";
            int second = Marshal.GetLastWin32Error();
            if (first == 1409 || second == 1409) return "Ctrl+Alt+B 已被其他软件占用（Win32 1409）";
            return "Ctrl+Alt+B 注册失败（Win32 " + second.ToString() + "）";
        }

        public static void Unregister(IntPtr hwnd)
        {
            if (hwnd == IntPtr.Zero) return;
            Native.UnregisterHotKey(hwnd, HotkeyId);
        }
    }

    public sealed class HotkeyForm : Form
    {
        public event EventHandler HotkeyPressed;

        public HotkeyForm()
        {
            ShowInTaskbar = false;
            FormBorderStyle = FormBorderStyle.FixedToolWindow;
            StartPosition = FormStartPosition.Manual;
            Location = new Point(-32000, -32000);
            Size = new Size(1, 1);
            Opacity = 0;
            Text = "BrowseKit.Tray";
        }

        protected override bool ShowWithoutActivation
        {
            get { return true; }
        }

        protected override CreateParams CreateParams
        {
            get
            {
                CreateParams cp = base.CreateParams;
                cp.ExStyle |= 0x00000080;
                cp.ExStyle |= 0x08000000;
                return cp;
            }
        }

        protected override void WndProc(ref Message m)
        {
            if (m.Msg == Native.WmHotkey)
            {
                EventHandler handler = HotkeyPressed;
                if (handler != null) handler(this, EventArgs.Empty);
            }
            base.WndProc(ref m);
        }
    }

    public static class TrayIconFactory
    {
        public static Icon Create()
        {
            using (Bitmap bmp = new Bitmap(32, 32))
            using (Graphics g = Graphics.FromImage(bmp))
            {
                g.SmoothingMode = SmoothingMode.AntiAlias;
                g.TextRenderingHint = TextRenderingHint.AntiAliasGridFit;
                g.Clear(Color.Transparent);
                using (SolidBrush brush = new SolidBrush(Color.FromArgb(255, 27, 110, 194)))
                {
                    g.FillEllipse(brush, 1, 1, 30, 30);
                }
                using (Font font = new Font("Segoe UI", 16, FontStyle.Bold, GraphicsUnit.Pixel))
                using (StringFormat format = new StringFormat())
                {
                    format.Alignment = StringAlignment.Center;
                    format.LineAlignment = StringAlignment.Center;
                    g.DrawString("B", font, Brushes.White, new RectangleF(0, 1, 32, 32), format);
                }
                IntPtr hIcon = bmp.GetHicon();
                try
                {
                    using (Icon temp = Icon.FromHandle(hIcon))
                    {
                        return (Icon)temp.Clone();
                    }
                }
                finally
                {
                    Native.DestroyIcon(hIcon);
                }
            }
        }
    }

    internal static class OsInfo
    {
        private static readonly int build;
        private static readonly int ubr;

        static OsInfo()
        {
            build = ReadInt(@"SOFTWARE\Microsoft\Windows NT\CurrentVersion", "CurrentBuildNumber");
            ubr = ReadDword(@"SOFTWARE\Microsoft\Windows NT\CurrentVersion", "UBR");
        }

        public static int Build { get { return build; } }
        public static int Ubr { get { return ubr; } }

        private static int ReadInt(string path, string name)
        {
            try
            {
                using (Microsoft.Win32.RegistryKey key = Microsoft.Win32.Registry.LocalMachine.OpenSubKey(path))
                {
                    if (key == null) return 0;
                    object value = key.GetValue(name);
                    int parsed;
                    if (value != null && int.TryParse(value.ToString(), out parsed)) return parsed;
                }
            }
            catch { }
            return 0;
        }

        private static int ReadDword(string path, string name)
        {
            try
            {
                using (Microsoft.Win32.RegistryKey key = Microsoft.Win32.Registry.LocalMachine.OpenSubKey(path))
                {
                    if (key == null) return 0;
                    object value = key.GetValue(name);
                    if (value is int) return (int)value;
                }
            }
            catch { }
            return 0;
        }
    }

    internal static class StaThread
    {
        private sealed class Work
        {
            public Func<object> Func;
            public object Result;
            public Exception Error;
            public ManualResetEvent Done = new ManualResetEvent(false);
        }

        private static readonly Queue<Work> queue = new Queue<Work>();
        private static readonly AutoResetEvent signal = new AutoResetEvent(false);
        private static readonly Thread thread;

        static StaThread()
        {
            ManualResetEvent started = new ManualResetEvent(false);
            thread = new Thread(delegate ()
            {
                started.Set();
                while (true)
                {
                    signal.WaitOne();
                    while (true)
                    {
                        Work item = null;
                        lock (queue)
                        {
                            if (queue.Count == 0) break;
                            item = queue.Dequeue();
                        }
                        try { item.Result = item.Func(); }
                        catch (Exception ex) { item.Error = ex; }
                        item.Done.Set();
                    }
                }
            });
            thread.IsBackground = true;
            thread.SetApartmentState(ApartmentState.STA);
            thread.Name = "BrowseKit.VirtualDesktop";
            thread.Start();
            started.WaitOne();
        }

        public static T Invoke<T>(Func<T> func)
        {
            if (Thread.CurrentThread == thread) return func();
            Work item = new Work();
            item.Func = delegate { return func(); };
            lock (queue) { queue.Enqueue(item); }
            signal.Set();
            item.Done.WaitOne();
            if (item.Error != null) throw item.Error;
            return (T)item.Result;
        }
    }

    internal static class Engine
    {
        private static readonly Guid AppOnAllDesktops = new Guid("BB64D5B7-4DE3-4AB2-A87C-DB7601AEA7DC");
        private static readonly Guid WindowOnAllDesktops = new Guid("C2DDEA68-66F2-4CF9-8264-1BFD00FBBBAC");

        private static IVirtualDesktopManager publicManager;
        private static IVirtualDesktopManagerInternal internalManager;
        private static IApplicationViewCollection views;
        private static bool publicReady;
        private static bool internalReady;

        public static int GetCount()
        {
            EnsureInternal();
            return internalManager.GetCount();
        }

        public static int GetCurrentIndex()
        {
            EnsureInternal();
            return IndexOf(internalManager.GetCurrentDesktop().GetId());
        }

        public static string[] GetDesktopIds()
        {
            EnsureInternal();
            IVirtualDesktop[] desks = AllDesktops();
            string[] ids = new string[desks.Length];
            for (int i = 0; i < desks.Length; i++) ids[i] = desks[i].GetId().ToString("D");
            return ids;
        }

        public static bool IsOnCurrent(IntPtr hwnd)
        {
            RequireWindow(hwnd);
            EnsurePublic();
            return publicManager.IsWindowOnCurrentVirtualDesktop(hwnd);
        }

        public static string GetWindowDesktopId(IntPtr hwnd)
        {
            RequireWindow(hwnd);
            EnsurePublic();
            return publicManager.GetWindowDesktopId(hwnd).ToString("D");
        }

        public static int GetWindowDesktopIndex(IntPtr hwnd)
        {
            RequireWindow(hwnd);
            EnsurePublic();
            Guid id = publicManager.GetWindowDesktopId(hwnd);
            if (id == AppOnAllDesktops || id == WindowOnAllDesktops) return GetCurrentIndex();
            return IndexOf(id);
        }

        public static void MoveTo(IntPtr hwnd, int index)
        {
            RequireWindow(hwnd);
            EnsurePublic();
            EnsureInternal();
            IVirtualDesktop[] desks = AllDesktops();
            if (index < 0 || index >= desks.Length) throw new VirtualDesktopException("虚拟桌面索引越界：" + index.ToString());
            Guid id = desks[index].GetId();
            try
            {
                publicManager.MoveWindowToDesktop(hwnd, ref id);
            }
            catch (Exception ex)
            {
                MoveViaView(hwnd, desks[index], ex);
            }
            Guid now = publicManager.GetWindowDesktopId(hwnd);
            if (now != id)
            {
                MoveViaView(hwnd, desks[index], null);
                now = publicManager.GetWindowDesktopId(hwnd);
                if (now != id) throw new VirtualDesktopException("窗口移动后仍不在目标桌面。");
            }
        }

        public static int EnsureCount(int minimum)
        {
            if (minimum < 1) minimum = 1;
            if (minimum > 16) throw new VirtualDesktopException("拒绝创建过多虚拟桌面。");
            EnsureInternal();
            int count = internalManager.GetCount();
            if (count >= minimum) return count;
            Guid stay = internalManager.GetCurrentDesktop().GetId();
            while (internalManager.GetCount() < minimum)
            {
                IVirtualDesktop created = internalManager.CreateDesktop();
                if (created == null) throw new VirtualDesktopException("创建虚拟桌面返回空对象。");
            }
            Guid now = internalManager.GetCurrentDesktop().GetId();
            if (now != stay)
            {
                IVirtualDesktop back = FindById(stay);
                if (back != null) internalManager.SwitchDesktop(back);
            }
            int after = internalManager.GetCount();
            if (after < minimum) throw new VirtualDesktopException("创建虚拟桌面后数量仍不足。");
            return after;
        }

        public static void SwitchTo(int index)
        {
            EnsureInternal();
            IVirtualDesktop[] desks = AllDesktops();
            if (index < 0 || index >= desks.Length) throw new VirtualDesktopException("虚拟桌面索引越界：" + index.ToString());
            internalManager.SwitchDesktop(desks[index]);
        }

        public static void RemoveById(string desktopId)
        {
            if (string.IsNullOrEmpty(desktopId)) throw new VirtualDesktopException("桌面标识为空。");
            Guid id;
            if (!Guid.TryParse(desktopId, out id)) throw new VirtualDesktopException("桌面标识非法。");
            EnsureInternal();
            IVirtualDesktop[] desks = AllDesktops();
            if (desks.Length <= 1) throw new VirtualDesktopException("至少保留一个虚拟桌面。");
            int index = -1;
            for (int i = 0; i < desks.Length; i++)
            {
                if (desks[i].GetId() == id) { index = i; break; }
            }
            if (index < 0) return;
            if (index == 0) throw new VirtualDesktopException("拒绝移除第 1 个虚拟桌面。");
            Guid current = internalManager.GetCurrentDesktop().GetId();
            if (current == id) internalManager.SwitchDesktop(desks[0]);
            internalManager.RemoveDesktop(desks[index], desks[0]);
        }

        private static void MoveViaView(IntPtr hwnd, IVirtualDesktop desktop, Exception ignored)
        {
            EnsureViews();
            IApplicationView view;
            int hr = views.GetViewForHwnd(hwnd, out view);
            if (hr != 0 || view == null)
            {
                string suffix = ignored == null ? "" : "；公开接口：" + ignored.Message;
                throw new VirtualDesktopException("无法取得窗口视图，HRESULT 0x" + hr.ToString("X8") + suffix);
            }
            internalManager.MoveViewToDesktop(view, desktop);
        }

        private static void RequireWindow(IntPtr hwnd)
        {
            if (hwnd == IntPtr.Zero || !Native.IsWindow(hwnd)) throw new VirtualDesktopException("窗口句柄无效。");
        }

        private static void EnsurePublic()
        {
            if (publicReady) return;
            Type coclass = Type.GetTypeFromCLSID(new Guid("AA509086-5CA9-4C25-8F95-589D3C07B48A"));
            if (coclass == null) throw new VirtualDesktopException("系统缺少 VirtualDesktopManager 组件。");
            publicManager = (IVirtualDesktopManager)Activator.CreateInstance(coclass);
            publicReady = true;
        }

        private static void EnsureInternal()
        {
            if (internalReady) return;
            int build = OsInfo.Build;
            if (build < 26100)
            {
                throw new VirtualDesktopException("当前 Windows Build " + build.ToString() + " 低于 26100，未内置本组件使用的虚拟桌面接口。");
            }
            Type shellType = Type.GetTypeFromCLSID(new Guid("C2F03A33-21F5-47FA-B4BB-156362A2F239"));
            if (shellType == null) throw new VirtualDesktopException("系统缺少 ImmersiveShell。");
            IServiceProvider10 shell = (IServiceProvider10)Activator.CreateInstance(shellType);
            Guid sid = new Guid("C5E0CDCA-7B6E-41B2-9FC4-D93975CC467B");
            Guid iid = typeof(IVirtualDesktopManagerInternal).GUID;
            object raw;
            int hr = shell.QueryService(ref sid, ref iid, out raw);
            if (hr != 0 || raw == null)
            {
                throw new VirtualDesktopException("虚拟桌面内部接口不可用，HRESULT 0x" + hr.ToString("X8") + "。Build " + OsInfo.Build.ToString() + "." + OsInfo.Ubr.ToString() + " 可能已更换 COM 接口，请改用 Win+Ctrl+→ 手动切换。");
            }
            internalManager = (IVirtualDesktopManagerInternal)raw;
            int count = internalManager.GetCount();
            if (count < 1 || count > 64)
            {
                internalManager = null;
                throw new VirtualDesktopException("虚拟桌面数量异常（" + count.ToString() + "），Build " + OsInfo.Build.ToString() + " 的接口布局可能已变化。请改用 Win+Ctrl+→ 手动切换。");
            }
            internalReady = true;
        }

        private static void EnsureViews()
        {
            if (views != null) return;
            EnsureInternal();
            Type shellType = Type.GetTypeFromCLSID(new Guid("C2F03A33-21F5-47FA-B4BB-156362A2F239"));
            IServiceProvider10 shell = (IServiceProvider10)Activator.CreateInstance(shellType);
            Guid av = new Guid("1841C6D7-4F9D-42C0-AF41-8747538F10E5");
            object raw;
            int hr = shell.QueryService(ref av, ref av, out raw);
            if (hr != 0 || raw == null) throw new VirtualDesktopException("无法取得窗口视图集合，HRESULT 0x" + hr.ToString("X8"));
            views = (IApplicationViewCollection)raw;
        }

        private static int IndexOf(Guid id)
        {
            IVirtualDesktop[] desks = AllDesktops();
            for (int i = 0; i < desks.Length; i++)
            {
                if (desks[i].GetId() == id) return i;
            }
            return -1;
        }

        private static IVirtualDesktop FindById(Guid id)
        {
            IVirtualDesktop[] desks = AllDesktops();
            for (int i = 0; i < desks.Length; i++)
            {
                if (desks[i].GetId() == id) return desks[i];
            }
            return null;
        }

        private static IVirtualDesktop[] AllDesktops()
        {
            EnsureInternal();
            IObjectArray array;
            internalManager.GetDesktops(out array);
            if (array == null) throw new VirtualDesktopException("GetDesktops 返回空。");
            try
            {
                int count;
                array.GetCount(out count);
                if (count < 1 || count > 64) throw new VirtualDesktopException("GetDesktops 数量异常：" + count.ToString());
                IVirtualDesktop[] desks = new IVirtualDesktop[count];
                Guid iid = typeof(IVirtualDesktop).GUID;
                for (int i = 0; i < count; i++)
                {
                    object obj;
                    array.GetAt(i, ref iid, out obj);
                    desks[i] = (IVirtualDesktop)obj;
                    if (desks[i] == null) throw new VirtualDesktopException("桌面对象为空，索引 " + i.ToString());
                }
                return desks;
            }
            finally
            {
                Marshal.ReleaseComObject(array);
            }
        }
    }

    internal static class WindowEnum
    {
        public static long FindMain(int[] processIds)
        {
            if (processIds == null || processIds.Length == 0) return 0;
            long best = 0;
            long bestArea = -1;
            Native.EnumProc proc = delegate (IntPtr hwnd, IntPtr lParam)
            {
                uint pid;
                Native.GetWindowThreadProcessId(hwnd, out pid);
                if (!ContainsPid(processIds, (int)pid)) return true;
                long area;
                if (!IsChromeMain(hwnd, out area)) return true;
                if (area > bestArea)
                {
                    bestArea = area;
                    best = hwnd.ToInt64();
                }
                return true;
            };
            Native.EnumWindows(proc, IntPtr.Zero);
            GC.KeepAlive(proc);
            return best;
        }

        public static string[] ListMain()
        {
            List<string> rows = new List<string>();
            Native.EnumProc proc = delegate (IntPtr hwnd, IntPtr lParam)
            {
                long area;
                if (!IsChromeMain(hwnd, out area)) return true;
                uint pid;
                Native.GetWindowThreadProcessId(hwnd, out pid);
                rows.Add(hwnd.ToInt64().ToString() + "|" + pid.ToString());
                return true;
            };
            Native.EnumWindows(proc, IntPtr.Zero);
            GC.KeepAlive(proc);
            return rows.ToArray();
        }

        private static bool ContainsPid(int[] processIds, int pid)
        {
            for (int i = 0; i < processIds.Length; i++)
            {
                if (processIds[i] == pid) return true;
            }
            return false;
        }

        private static bool IsChromeMain(IntPtr hwnd, out long area)
        {
            area = 0;
            if (Native.GetWindow(hwnd, Native.GwOwner) != IntPtr.Zero) return false;
            StringBuilder cls = new StringBuilder(256);
            Native.GetClassName(hwnd, cls, cls.Capacity);
            if (cls.ToString() != "Chrome_WidgetWin_1") return false;
            int ex = Native.GetExStyle(hwnd);
            if ((ex & Native.WsExToolWindow) != 0) return false;
            if (Native.GetWindowTextLength(hwnd) <= 0) return false;
            int cloaked;
            Native.DwmGetWindowAttribute(hwnd, Native.DwmwaCloaked, out cloaked, 4);
            if (!Native.IsWindowVisible(hwnd) && cloaked == 0) return false;
            Native.WindowPlacement placement = Native.WindowPlacement.Create();
            if (!Native.GetWindowPlacement(hwnd, ref placement)) return false;
            int width = placement.Normal.Right - placement.Normal.Left;
            int height = placement.Normal.Bottom - placement.Normal.Top;
            if (width < 200 || height < 120) return false;
            area = (long)width * height;
            return true;
        }
    }

    internal static class Native
    {
        public const int SwShow = 5;
        public const int SwRestore = 9;
        public const uint GwOwner = 4;
        public const int WsExToolWindow = 0x00000080;
        public const int DwmwaCloaked = 14;
        public const int WmHotkey = 0x0312;
        public const uint ModAlt = 0x0001;
        public const uint ModControl = 0x0002;
        public const uint ModNorepeat = 0x4000;
        public const uint VkB = 0x42;
        public const byte VkMenu = 0x12;
        public const uint KeyeventfKeyup = 0x0002;

        public delegate bool EnumProc(IntPtr hWnd, IntPtr lParam);

        [StructLayout(LayoutKind.Sequential)]
        public struct Point
        {
            public int X;
            public int Y;
        }

        [StructLayout(LayoutKind.Sequential)]
        public struct Rect
        {
            public int Left;
            public int Top;
            public int Right;
            public int Bottom;
        }

        [StructLayout(LayoutKind.Sequential)]
        public struct WindowPlacement
        {
            public int Length;
            public int Flags;
            public int ShowCmd;
            public Point MinPosition;
            public Point MaxPosition;
            public Rect Normal;

            public static WindowPlacement Create()
            {
                WindowPlacement value = new WindowPlacement();
                value.Length = Marshal.SizeOf(typeof(WindowPlacement));
                return value;
            }
        }

        [DllImport("user32.dll")]
        public static extern bool EnumWindows(EnumProc lpEnumFunc, IntPtr lParam);

        [DllImport("user32.dll", CharSet = CharSet.Unicode)]
        public static extern int GetClassName(IntPtr hWnd, StringBuilder lpClassName, int nMaxCount);

        [DllImport("user32.dll", CharSet = CharSet.Unicode)]
        public static extern int GetWindowTextLength(IntPtr hWnd);

        [DllImport("user32.dll")]
        public static extern bool IsWindowVisible(IntPtr hWnd);

        [DllImport("user32.dll")]
        public static extern bool IsWindow(IntPtr hWnd);

        [DllImport("user32.dll")]
        public static extern bool IsIconic(IntPtr hWnd);

        [DllImport("user32.dll")]
        public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);

        [DllImport("user32.dll")]
        public static extern bool SetForegroundWindow(IntPtr hWnd);

        [DllImport("user32.dll")]
        public static extern IntPtr GetForegroundWindow();

        [DllImport("user32.dll")]
        public static extern bool BringWindowToTop(IntPtr hWnd);

        [DllImport("user32.dll")]
        public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint lpdwProcessId);

        [DllImport("user32.dll")]
        public static extern IntPtr GetWindow(IntPtr hWnd, uint uCmd);

        [DllImport("user32.dll")]
        public static extern bool GetWindowPlacement(IntPtr hWnd, ref WindowPlacement lpwndpl);

        [DllImport("user32.dll")]
        public static extern bool AttachThreadInput(uint idAttach, uint idAttachTo, bool fAttach);

        [DllImport("kernel32.dll")]
        public static extern uint GetCurrentThreadId();

        [DllImport("user32.dll")]
        public static extern void keybd_event(byte bVk, byte bScan, uint dwFlags, UIntPtr dwExtraInfo);

        [DllImport("user32.dll", SetLastError = true)]
        public static extern bool RegisterHotKey(IntPtr hWnd, int id, uint fsModifiers, uint vk);

        [DllImport("user32.dll", SetLastError = true)]
        public static extern bool UnregisterHotKey(IntPtr hWnd, int id);

        [DllImport("user32.dll", SetLastError = true)]
        public static extern bool DestroyIcon(IntPtr hIcon);

        [DllImport("dwmapi.dll")]
        public static extern int DwmGetWindowAttribute(IntPtr hwnd, int dwAttribute, out int pvAttribute, int cbAttribute);

        [DllImport("user32.dll", EntryPoint = "GetWindowLong", CharSet = CharSet.Unicode)]
        private static extern int GetWindowLong32(IntPtr hWnd, int nIndex);

        [DllImport("user32.dll", EntryPoint = "GetWindowLongPtr", CharSet = CharSet.Unicode)]
        private static extern IntPtr GetWindowLongPtr64(IntPtr hWnd, int nIndex);

        public static int GetExStyle(IntPtr hwnd)
        {
            const int GWL_EXSTYLE = -20;
            if (IntPtr.Size == 8)
            {
                return unchecked((int)GetWindowLongPtr64(hwnd, GWL_EXSTYLE).ToInt64());
            }
            return GetWindowLong32(hwnd, GWL_EXSTYLE);
        }
    }

    [ComImport]
    [InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    [Guid("6D5140C1-7436-11CE-8034-00AA006009FA")]
    internal interface IServiceProvider10
    {
        [PreserveSig]
        int QueryService(ref Guid guidService, ref Guid riid, [MarshalAs(UnmanagedType.Interface)] out object ppvObject);
    }

    [ComImport]
    [InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    [Guid("A5CD92FF-29BE-454C-8D04-D82879FB3F1B")]
    internal interface IVirtualDesktopManager
    {
        bool IsWindowOnCurrentVirtualDesktop(IntPtr topLevelWindow);
        Guid GetWindowDesktopId(IntPtr topLevelWindow);
        void MoveWindowToDesktop(IntPtr topLevelWindow, ref Guid desktopId);
    }

    [ComImport]
    [InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    [Guid("92CA9DCD-5622-4BBA-A805-5E9F541BD8C9")]
    internal interface IObjectArray
    {
        void GetCount(out int count);
        void GetAt(int index, ref Guid iid, [MarshalAs(UnmanagedType.Interface)] out object obj);
    }

    [ComImport]
    [InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    [Guid("372E1D3B-38D3-42E4-A15B-8AB2B178F513")]
    internal interface IApplicationView
    {
    }

    [ComImport]
    [InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    [Guid("1841C6D7-4F9D-42C0-AF41-8747538F10E5")]
    internal interface IApplicationViewCollection
    {
        [PreserveSig]
        int GetViews(out IntPtr array);
        [PreserveSig]
        int GetViewsByZOrder(out IntPtr array);
        [PreserveSig]
        int GetViewsByAppUserModelId(IntPtr id, out IntPtr array);
        [PreserveSig]
        int GetViewForHwnd(IntPtr hwnd, out IApplicationView view);
    }

    [ComImport]
    [InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    [Guid("3F07F4BE-B107-441A-AF0F-39D82529072C")]
    internal interface IVirtualDesktop
    {
        [PreserveSig]
        int IsViewVisible(IntPtr view, out int visible);
        Guid GetId();
    }

    [ComImport]
    [InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    [Guid("53F5CA0B-158F-4124-900C-057158060B27")]
    internal interface IVirtualDesktopManagerInternal
    {
        int GetCount();
        void MoveViewToDesktop(IApplicationView view, IVirtualDesktop desktop);
        int CanViewMoveDesktops(IntPtr view);
        IVirtualDesktop GetCurrentDesktop();
        void GetDesktops(out IObjectArray desktops);
        [PreserveSig]
        int GetAdjacentDesktop(IntPtr from, int direction, out IntPtr desktop);
        void SwitchDesktop(IVirtualDesktop desktop);
        void SwitchDesktopAndMoveForegroundView(IVirtualDesktop desktop);
        IVirtualDesktop CreateDesktop();
        void MoveDesktop(IVirtualDesktop desktop, int index);
        void RemoveDesktop(IVirtualDesktop desktop, IVirtualDesktop fallback);
    }
}
