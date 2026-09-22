package dev.continuum.chat

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class ActivityDisplayParserTest {
    @Test
    fun `detects trampoline task on main display while launcher remains virtual`() {
        val snapshot = ActivityDisplayParser.parse(
            stackOutput = """
                RootTask id=41 bounds=[0,0][1080,2400] displayId=0 userId=0
                 taskId=41: com.taobao.taobao/.Welcome userId=0 visible=true topActivity=com.taobao.taobao/com.taobao.tao.TBMainActivity
                RootTask id=52 bounds=[0,0][720,1280] displayId=14 userId=0
                 taskId=52: com.taobao.taobao/.Welcome userId=0 visible=true topActivity=com.taobao.taobao/.Welcome
            """.trimIndent(),
            activitiesOutput = """
                Display #0 (activities from top to bottom):
                  RootTask #41
                    * Task{abc #41 type=standard A=com.taobao.taobao}
                      topResumedActivity=ActivityRecord{123 u0 com.taobao.taobao/com.taobao.tao.TBMainActivity t41}
                      mFocusedApp=ActivityRecord{123 u0 com.taobao.taobao/com.taobao.tao.TBMainActivity t41}
                Display #14 (activities from top to bottom):
                  RootTask #52
                    * Task{def #52 type=standard A=com.taobao.taobao}
                      * Hist #0: ActivityRecord{456 u0 com.taobao.taobao/.Welcome t52}
            """.trimIndent(),
            targetPackage = "com.taobao.taobao",
        )

        assertEquals(setOf(0, 14), snapshot.targetTasks.map { it.displayId }.toSet())
        assertTrue(snapshot.targetTasks.single { it.taskId == 41 }.active)
        assertTrue(snapshot.targetTasks.single { it.taskId == 52 }.active)
        assertTrue(snapshot.mainDisplayHasPackage("com.taobao.taobao"))
    }

    @Test
    fun `does not report main display takeover by unrelated foreground app`() {
        val snapshot = ActivityDisplayParser.parse(
            stackOutput = """
                RootTask id=9 bounds=[0,0][1080,2400] displayId=0 userId=0
                 taskId=9: com.miui.home/.launcher.Launcher userId=0 visible=true topActivity=com.miui.home/.launcher.Launcher
                RootTask id=52 bounds=[0,0][720,1280] displayId=14 userId=0
                 taskId=52: com.taobao.taobao/.Welcome userId=0 visible=true topActivity=com.taobao.taobao/com.taobao.tao.TBMainActivity
            """.trimIndent(),
            activitiesOutput = """
                Display #0 (activities from top to bottom):
                  RootTask #9
                    * Task{abc #9 type=home A=com.miui.home}
                      topResumedActivity=ActivityRecord{123 u0 com.miui.home/.launcher.Launcher t9}
                Display #14 (activities from top to bottom):
                  RootTask #52
                    * Task{def #52 type=standard A=com.taobao.taobao}
                      topResumedActivity=ActivityRecord{456 u0 com.taobao.taobao/com.taobao.tao.TBMainActivity t52}
            """.trimIndent(),
            targetPackage = "com.taobao.taobao",
        )

        assertFalse(snapshot.mainDisplayHasPackage("com.taobao.taobao"))
        assertEquals(listOf(14), snapshot.targetTasks.map { it.displayId })
        assertTrue(snapshot.targetTasks.single().active)
    }

    @Test
    fun `later dumpsys display overrides stale active stack location`() {
        val snapshot = ActivityDisplayParser.parse(
            stackOutput = """
                RootTask id=7670 bounds=[0,0][720,1280] displayId=19 userId=0
                 taskId=7670: com.taobao.taobao/.Welcome userId=0 visible=true topActivity=com.taobao.taobao/com.taobao.tao.TBMainActivity
                RootTask id=7674 bounds=[0,0][720,1280] displayId=19 userId=0
                 taskId=7674: com.taobao.taobao/.Welcome userId=0 visible=true topActivity=com.taobao.taobao/com.taobao.tao.TBMainActivity
            """.trimIndent(),
            activitiesOutput = """
                Display #0 (activities from top to bottom):
                  RootTask #7674
                    * Task{abc #7674 type=standard A=com.taobao.taobao}
                      topResumedActivity=ActivityRecord{123 u0 com.taobao.taobao/com.taobao.tao.TBMainActivity t7674}
                      mFocusedApp=ActivityRecord{123 u0 com.taobao.taobao/com.taobao.tao.TBMainActivity t7674}
                Display #19 (activities from top to bottom):
                  RootTask #7670
                    * Task{def #7670 type=standard A=com.taobao.taobao}
                      * Hist #0: ActivityRecord{456 u0 com.taobao.taobao/com.taobao.tao.TBMainActivity t7670}
            """.trimIndent(),
            targetPackage = "com.taobao.taobao",
        )

        val byId = snapshot.targetTasks.associateBy { it.taskId }
        assertEquals(0, byId.getValue(7674).displayId)
        assertTrue(byId.getValue(7674).active)
        assertEquals(19, byId.getValue(7670).displayId)
        assertTrue(snapshot.mainDisplayHasPackage("com.taobao.taobao"))
    }

    @Test
    fun `retains root membership needed for bounded relocation safety`() {
        val snapshot = ActivityDisplayParser.parse(
            stackOutput = """
                RootTask id=61 bounds=[0,0][1080,2400] displayId=0 userId=0
                 taskId=61: com.taobao.taobao/.Welcome userId=0 visible=true topActivity=com.taobao.taobao/.Welcome
                 taskId=60: com.example.other/.Main userId=0 visible=true topActivity=com.taobao.taobao/.Welcome
            """.trimIndent(),
            activitiesOutput = "",
            targetPackage = "com.taobao.taobao",
        )

        assertEquals(setOf(60, 61), snapshot.allTasksByRoot.getValue(61).map { it.taskId }.toSet())
        assertEquals(listOf(61), snapshot.targetTasks.map { it.taskId })
    }
    @Test
    fun `global resumed activity is not attributed to the last physical display`() {
        val snapshot = ActivityDisplayParser.parse(
            stackOutput = """
                RootTask id=100 bounds=[0,0][1200,2608] displayId=0 userId=0
                 taskId=100: dev.continuum.chat/dev.continuum.chat.MainActivity userId=0 visible=true topActivity=ComponentInfo{dev.continuum.chat/dev.continuum.chat.MainActivity}
                RootTask id=7726 bounds=[0,0][720,1280] displayId=29 userId=0
                 taskId=7726: com.taobao.taobao/com.taobao.tao.welcome.Welcome userId=0 visible=true topActivity=ComponentInfo{com.taobao.taobao/com.taobao.tao.TBMainActivity}
            """.trimIndent(),
            activitiesOutput = """
                Display #0 (activities from top to bottom):
                  * Task{main #100 type=standard A=dev.continuum.chat visible=true}
                    topResumedActivity=ActivityRecord{111 u0 dev.continuum.chat/dev.continuum.chat.MainActivity t100}
                Display #29 (activities from top to bottom):
                  * Task{vd #7726 type=standard A=com.taobao.taobao visible=true}
                    topResumedActivity=ActivityRecord{222 u0 com.taobao.taobao/com.taobao.tao.TBMainActivity t7726}
                  Resumed activities in task display areas (from top to bottom):
                    Resumed: ActivityRecord{222 u0 com.taobao.taobao/com.taobao.tao.TBMainActivity t7726}
                Display #1 (activities from top to bottom):
                  * Task{sub #4 type=home A=com.xiaomi.subscreencenter visible=true}
                  Resumed activities in task display areas (from top to bottom):
                    Resumed: ActivityRecord{444 u0 com.xiaomi.subscreencenter/.SubScreenLauncher t4}
                  ResumedActivity: ActivityRecord{222 u0 com.taobao.taobao/com.taobao.tao.TBMainActivity t7726}
                ActivityTaskSupervisor state:
                  Display: mDisplayId=0 (organized)
            """.trimIndent(),
            targetPackage = "com.taobao.taobao",
        )

        assertFalse(snapshot.mainDisplayHasPackage("com.taobao.taobao"))
        assertEquals(29, snapshot.targetTasks.single().displayId)
        assertTrue(snapshot.targetTasks.single().active)
    }

    @Test
    fun `trusted virtual display is not invalidated by global supervisor focus dump`() {
        val snapshot = ActivityDisplayParser.parse(
            stackOutput = """
                RootTask id=100 bounds=[0,0][1200,2608] displayId=0 userId=0
                 taskId=100: dev.continuum.chat/dev.continuum.chat.MainActivity userId=0 visible=true topActivity=ComponentInfo{dev.continuum.chat/dev.continuum.chat.MainActivity}
                RootTask id=7715 bounds=[0,0][720,1280] displayId=28 userId=0
                 taskId=7715: com.taobao.taobao/com.taobao.tao.welcome.Welcome userId=0 visible=true topActivity=ComponentInfo{com.taobao.taobao/com.taobao.tao.TBMainActivity}
            """.trimIndent(),
            activitiesOutput = """
                Display #0 (activities from top to bottom):
                  * Task{main #100 type=standard A=dev.continuum.chat visible=true}
                    topResumedActivity=ActivityRecord{111 u0 dev.continuum.chat/dev.continuum.chat.MainActivity t100}
                Display #28 (activities from top to bottom):
                  * Task{vd #7715 type=standard A=com.taobao.taobao visible=true}
                    topResumedActivity=ActivityRecord{222 u0 com.taobao.taobao/com.taobao.tao.TBMainActivity t7715}
                ActivityTaskSupervisor state:
                  Display: mDisplayId=0 (organized)
                  mFocusedApp=ActivityRecord{333 u0 com.taobao.taobao/com.taobao.tao.TBMainActivity t7715}
                  * Task{stale #7715 type=standard A=com.taobao.taobao visible=false}
            """.trimIndent(),
            targetPackage = "com.taobao.taobao",
        )

        assertEquals("dev.continuum.chat/dev.continuum.chat.MainActivity", snapshot.mainTopActivity)
        assertFalse(snapshot.mainDisplayHasPackage("com.taobao.taobao"))
        assertEquals(28, snapshot.targetTasks.single().displayId)
        assertTrue(snapshot.targetTasks.single().active)
    }

}
