#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NAMESPACE="${NAMESPACE:-moodle}"
MOODLE_CONTAINER="${MOODLE_CONTAINER:-moodle}"
USER_PREFIX="${USER_PREFIX:-user}"
USER_PASSWORD="${USER_PASSWORD:-123456}"
USER_COUNT="${USER_COUNT:-500}"
TEACHER_PREFIX="${TEACHER_PREFIX:-teacher}"
TEACHER_PASSWORD="${TEACHER_PASSWORD:-123456}"
TEACHER_COUNT="${TEACHER_COUNT:-100}"
COURSE_SHORTNAME="${COURSE_SHORTNAME:-TOAN101}"
COURSE_FULLNAME="${COURSE_FULLNAME:-BASIC MATH}"
QUIZ_NAME="${QUIZ_NAME:-BASIC MATH QUIZ}"
ANNOUNCEMENT_SUBJECT="${ANNOUNCEMENT_SUBJECT:-Giới thiệu khóa học Toán cấp 2}"

command -v kubectl >/dev/null 2>&1 || { echo "kubectl is required"; exit 1; }
[[ "${USER_COUNT}" =~ ^[0-9]+$ && "${TEACHER_COUNT}" =~ ^[0-9]+$ ]] || {
  echo "USER_COUNT and TEACHER_COUNT must be positive integers"; exit 1;
}

if [[ -z "${KUBECONFIG:-}" ]]; then
  ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
  for kc in "${ROOT_DIR}"/digitalocean/kubeconfig{,-production,-staging}; do [[ -f "${kc}" ]] && { export KUBECONFIG="${kc}"; echo "Auto-detected KUBECONFIG=${KUBECONFIG}"; break; }; done
fi

POD="${MOODLE_POD:-}"
[[ -z "${POD}" ]] && POD="$(kubectl -n "${NAMESPACE}" get pod -l 'app.kubernetes.io/instance=moodle,app.kubernetes.io/name=moodle,role=web' -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
[[ -n "${POD}" ]] || { echo "Cannot find Moodle web pod. Set MOODLE_POD explicitly or export KUBECONFIG."; exit 1; }

echo "Using pod: ${POD}"
echo "Generating ${USER_COUNT} students (${USER_PREFIX}0001…) and ${TEACHER_COUNT} teachers (${TEACHER_PREFIX}0001…)"

kubectl -n "${NAMESPACE}" exec -i "${POD}" -c "${MOODLE_CONTAINER}" -- sh -c "cat > /tmp/seed_k6_auth_quiz.php" <<'PHP'
<?php
define('CLI_SCRIPT', true);
require('/var/www/html/config.php');
require_once($CFG->dirroot . '/lib/clilib.php');
require_once($CFG->dirroot . '/course/lib.php');
require_once($CFG->dirroot . '/course/modlib.php');
require_once($CFG->dirroot . '/user/lib.php');
require_once($CFG->dirroot . '/mod/quiz/lib.php');
require_once($CFG->dirroot . '/mod/quiz/locallib.php');
require_once($CFG->libdir . '/questionlib.php');
require_once($CFG->libdir . '/moodlelib.php');
require_once($CFG->libdir . '/gradelib.php');

$CFG->noemailever = true;
$CFG->sendmail = '/bin/true';
set_config('noemailever', 1);
set_config('sendmail', '/bin/true');
\core\session\manager::set_user(get_admin());

[$o] = cli_get_params([
    'userprefix' => 'user', 'userpassword' => '123456', 'usercount' => 100,
    'teacherprefix' => 'teacher', 'teacherpassword' => '123456', 'teachercount' => 10,
    'courseshortname' => 'TOAN101', 'coursefullname' => 'Môn Toán Cấp 2',
    'quizname' => 'Quiz Toán Cấp 2', 'announcementsubject' => 'Giới thiệu khóa học Toán cấp 2',
], []);

function get_or_create_user(string $username, string $password, string $firstname, string $lastname): stdClass {
    global $CFG, $DB;
    $user = $DB->get_record('user', ['username' => $username, 'deleted' => 0]);
    if ($user) {
        if (!validate_internal_user_password($user, $password)) update_internal_user_password($user, $password);
        return $user;
    }
    $user = (object)[
        'auth' => 'manual', 'confirmed' => 1, 'username' => $username,
        'password' => hash_internal_user_password($password),
        'firstname' => $firstname, 'lastname' => $lastname, 'email' => $username . '@load.local',
        'mnethostid' => $CFG->mnet_localhost_id, 'lang' => 'vi', 'maildisplay' => 2,
        'mailformat' => 1, 'maildigest' => 0, 'autosubscribe' => 1, 'trackforums' => 0,
        'timecreated' => time(), 'timemodified' => time(),
    ];
    $user->id = user_create_user($user, false, false);
    return $user;
}

function enrol_course_user(int $courseid, int $userid, string $roleshortname, int $fallbackroleid): void {
    global $DB;
    $roleid = (int)$DB->get_field('role', 'id', ['shortname' => $roleshortname], IGNORE_MISSING) ?: $fallbackroleid;
    if (!is_enrolled(context_course::instance($courseid), $userid)) enrol_try_internal_enrol($courseid, $userid, $roleid);
}

function quiz_defaults(stdClass $q): stdClass {
    foreach ([
        'intro' => '<p>Quiz Toán cấp 2 gồm 5 câu hỏi ngắn.</p>', 'introformat' => FORMAT_HTML,
        'timeopen' => 0, 'timeclose' => 0, 'timelimit' => 0, 'attempts' => 0, 'attemptonlast' => 0,
        'overduehandling' => 'autosubmit', 'graceperiod' => 0, 'preferredbehaviour' => 'deferredfeedback',
        'canredoquestions' => 0, 'grademethod' => QUIZ_GRADEHIGHEST, 'decimalpoints' => 2,
        'questiondecimalpoints' => -1, 'questionsperpage' => 0, 'navmethod' => QUIZ_NAVMETHOD_FREE,
        'shuffleanswers' => 1, 'grade' => 10, 'password' => '', 'quizpassword' => '',
        'subnet' => '', 'browsersecurity' => '-', 'showblocks' => 0, 'showuserpicture' => 0,
        'feedbackboundarycount' => 0, 'feedbackboundaries' => [0 => ''],
        'feedbacktext' => [['text' => '', 'format' => FORMAT_HTML, 'itemid' => 0]],
    ] as $key => $value) $q->{$key} = $value;
    return $q;
}

function quiz_moduleinfo(string $name, int $moduleid): stdClass {
    return quiz_defaults((object)[
        'modulename' => 'quiz', 'module' => $moduleid, 'section' => 0, 'name' => $name,
        'visible' => 1, 'visibleoncoursepage' => 1, 'groupmode' => 0, 'groupingid' => 0,
        'cmidnumber' => '', 'completion' => 0, 'completionpassgrade' => 0,
        'completiongradeitemnumber' => null, 'completionview' => 0, 'completionexpected' => 0,
        'showdescription' => 0, 'downloadcontent' => 1, 'availabilityconditionsjson' => '', 'lang' => '',
    ]);
}

function sync_quiz_questions(stdClass $course, stdClass $quiz, int $cmid): void {
    global $DB;
    $ctx = context_course::instance($course->id);
    $qcat = $DB->get_record('question_categories', ['contextid' => $ctx->id, 'name' => 'Load test questions']);
    if (!$qcat) {
        $qcatid = $DB->insert_record('question_categories', (object)[
            'name' => 'Load test questions', 'contextid' => $ctx->id, 'info' => 'Auto-generated for k6 load test',
            'infoformat' => FORMAT_PLAIN, 'stamp' => substr(md5((string)microtime(true)), 0, 12),
            'parent' => 0, 'sortorder' => 999, 'idnumber' => null,
        ]);
        $qcat = $DB->get_record('question_categories', ['id' => $qcatid], '*', MUST_EXIST);
    }

    $DB->delete_records('quiz_slots', ['quizid' => $quiz->id]);
    $DB->delete_records('quiz_sections', ['quizid' => $quiz->id]);
    $DB->insert_record('quiz_sections', (object)['quizid' => $quiz->id, 'firstslot' => 1, 'heading' => '', 'shufflequestions' => 0]);

    foreach ([
        ['Giải phương trình bậc nhất', '<p>Giải phương trình: 3x + 7 = 61. Giá trị của x là bao nhiêu?</p>', '18'],
        ['Chu vi hình chữ nhật', '<p>Một hình chữ nhật có chiều dài 12 cm và chiều rộng 8 cm. Chu vi là bao nhiêu cm?</p>', '40'],
        ['Trung bình cộng', '<p>Tính trung bình cộng của các số 12, 15, 18 và 19.</p>', '16'],
        ['Tỉ số phần trăm', '<p>15% của 240 bằng bao nhiêu?</p>', '36'],
        ['Góc trong tam giác', '<p>Một tam giác có hai góc 45 độ và 65 độ. Góc còn lại bằng bao nhiêu độ?</p>', '70'],
    ] as [$name, $text, $rightanswer]) {
        $now = time();
        $qid = $DB->insert_record('question', (object)[
            'parent' => 0, 'name' => $name, 'questiontext' => $text, 'questiontextformat' => FORMAT_HTML,
            'generalfeedback' => '', 'generalfeedbackformat' => FORMAT_HTML, 'defaultmark' => 1,
            'penalty' => 0.3333333, 'qtype' => 'shortanswer', 'length' => 1,
            'stamp' => md5(uniqid((string)$now, true)), 'timecreated' => $now, 'timemodified' => $now,
            'createdby' => null, 'modifiedby' => null,
        ]);
        $DB->insert_record('qtype_shortanswer_options', (object)['questionid' => $qid, 'usecase' => 0]);
        foreach ([[$rightanswer, 1], ['*', 0]] as [$answer, $fraction]) {
            $DB->insert_record('question_answers', (object)[
                'question' => $qid, 'answer' => $answer, 'answerformat' => FORMAT_PLAIN,
                'fraction' => $fraction, 'feedback' => '', 'feedbackformat' => FORMAT_HTML,
            ]);
        }
        $qbeid = $DB->insert_record('question_bank_entries', (object)['questioncategoryid' => $qcat->id, 'idnumber' => null, 'ownerid' => null]);
        $DB->insert_record('question_versions', (object)['questionbankentryid' => $qbeid, 'version' => 1, 'questionid' => $qid, 'status' => 'ready']);
        quiz_add_quiz_question($qid, $quiz, 0, 1.0);
    }
    \mod_quiz\quiz_settings::create((int)$quiz->id)->get_grade_calculator()->recompute_quiz_sumgrades();
    quiz_repaginate_questions($quiz->id, 0);
}

function put_course_announcement(int $courseid, string $subject): int {
    global $DB;
    $forum = $DB->get_record('forum', ['course' => $courseid, 'type' => 'news'], '*', IGNORE_MULTIPLE);
    if (!$forum) throw new moodle_exception('Không tìm thấy Announcements có sẵn. Seed không tạo activity Announcements mới.');

    $html = '<h3>Chào mừng đến với khóa học Toán cấp 2</h3>'
        . '<p>Khóa học này giúp học sinh trung học cơ sở xây dựng nền tảng toán học chắc chắn, dễ hiểu và áp dụng được vào bài tập trên lớp. Nội dung tập trung vào cách đọc đề, phân tích dữ kiện, chọn phương pháp giải và trình bày bài làm rõ ràng.</p>'
        . '<p>Học sinh sẽ ôn tập số học, phân số, số thập phân, tỉ số phần trăm, biểu thức đại số, phương trình bậc nhất, hình học phẳng, chu vi, diện tích, góc trong tam giác, trung bình cộng, ước chung, bội chung và các bài toán có lời văn.</p>'
        . '<p>Mục tiêu của khóa học là giúp các em hiểu bản chất, tính toán cẩn thận và biết giải thích cách làm. Khi gặp một bài toán, học sinh cần xác định đề bài hỏi gì, dữ kiện nào quan trọng, công thức nào phù hợp và vì sao dùng công thức đó.</p>'
        . '<p>Cách học đề xuất là xem lý thuyết ngắn, đọc ví dụ mẫu, tự làm bài cơ bản rồi chuyển sang bài tổng hợp. Khi làm sai, học sinh cần tìm nguyên nhân: đọc nhầm đề, chọn sai công thức, tính toán chưa cẩn thận hay trình bày thiếu bước.</p>'
        . '<p>Giáo viên sẽ theo dõi kết quả quiz và tiến độ học để hỗ trợ từng nhóm học sinh. Những phần còn yếu sẽ được ôn lại bằng ví dụ đơn giản hơn; những em đã nắm chắc kiến thức có thể thử các câu hỏi mở rộng.</p>';
    $now = time();
    $admin = get_admin();
    $discussion = $DB->get_record('forum_discussions', ['forum' => $forum->id, 'name' => $subject], '*', IGNORE_MULTIPLE);

    if ($discussion && (int)$discussion->firstpost > 0) {
        $DB->update_record('forum_posts', (object)[
            'id' => $discussion->firstpost, 'userid' => $admin->id, 'subject' => $subject, 'message' => $html,
            'messageformat' => FORMAT_HTML, 'modified' => $now,
        ]);
        $DB->set_field('forum_discussions', 'timemodified', $now, ['id' => $discussion->id]);
    } else {
        $did = $DB->insert_record('forum_discussions', (object)[
            'course' => $courseid, 'forum' => $forum->id, 'name' => $subject, 'firstpost' => 0,
            'userid' => $admin->id, 'groupid' => -1, 'assessed' => 0, 'timemodified' => $now,
            'usermodified' => $admin->id, 'timestart' => 0, 'timeend' => 0,
        ]);
        $pid = $DB->insert_record('forum_posts', (object)[
            'discussion' => $did, 'parent' => 0, 'userid' => $admin->id, 'created' => $now, 'modified' => $now,
            'mailed' => 0, 'subject' => $subject, 'message' => $html, 'messageformat' => FORMAT_HTML,
            'messagetrust' => 0, 'attachment' => '', 'totalscore' => 0, 'mailnow' => 0,
            'deleted' => 0,
        ]);
        $DB->set_field('forum_discussions', 'firstpost', $pid, ['id' => $did]);
    }

    return (int)$DB->get_field_sql("
        SELECT cm.id FROM {course_modules} cm JOIN {modules} m ON m.id = cm.module
         WHERE cm.course = :courseid AND m.name = 'forum' AND cm.instance = :forumid
    ", ['courseid' => $courseid, 'forumid' => $forum->id], MUST_EXIST);
}

$userprefix = (string)$o['userprefix']; $userpassword = (string)$o['userpassword']; $usercount = (int)$o['usercount'];
$teacherprefix = (string)$o['teacherprefix']; $teacherpassword = (string)$o['teacherpassword']; $teachercount = (int)$o['teachercount'];
$courseshortname = (string)$o['courseshortname']; $coursefullname = (string)$o['coursefullname'];
$quizname = (string)$o['quizname']; $announcementsubject = (string)$o['announcementsubject'];

echo "STEP=course\n";
$course = $DB->get_record('course', ['shortname' => $courseshortname]);
if (!$course) {
    $course = create_course((object)['fullname' => $coursefullname, 'shortname' => $courseshortname, 'category' => 1, 'visible' => 1, 'newsitems' => 5]);
    echo "Created course: {$course->id}\n";
}

echo "STEP=users\n";
for ($i = 1; $i <= $usercount; $i++) {
    $suffix = str_pad((string)$i, 4, '0', STR_PAD_LEFT);
    $u = get_or_create_user($userprefix . $suffix, $userpassword, 'Học sinh', $suffix);
    enrol_course_user((int)$course->id, (int)$u->id, 'student', 5);
}

echo "STEP=teachers\n";
for ($i = 1; $i <= $teachercount; $i++) {
    $suffix = str_pad((string)$i, 4, '0', STR_PAD_LEFT);
    $u = get_or_create_user($teacherprefix . $suffix, $teacherpassword, 'Giáo viên', $suffix);
    enrol_course_user((int)$course->id, (int)$u->id, 'editingteacher', 3);
}

echo "STEP=quiz\n";
$quizcm = $DB->get_record_sql("
    SELECT cm.id, cm.instance FROM {course_modules} cm
      JOIN {modules} m ON m.id = cm.module JOIN {quiz} q ON q.id = cm.instance
     WHERE cm.course = :courseid AND m.name = 'quiz' AND q.name = :quizname
     ORDER BY cm.id ASC LIMIT 1
", ['courseid' => $course->id, 'quizname' => $quizname]);
if (!$quizcm) {
    $moduleid = $DB->get_field('modules', 'id', ['name' => 'quiz'], MUST_EXIST);
    $created = add_moduleinfo(quiz_moduleinfo($quizname, (int)$moduleid), $course);
    $quizcm = (object)['id' => $created->coursemodule, 'instance' => $created->instance];
    echo "Created quiz cmid: {$quizcm->id}\n";
} else {
    echo "Reused quiz cmid: {$quizcm->id}\n";
}

$quiz = quiz_defaults($DB->get_record('quiz', ['id' => $quizcm->instance], '*', MUST_EXIST));
$quiz->coursemodule = $quizcm->id;
$DB->update_record('quiz', (object)[
    'id' => $quiz->id, 'intro' => $quiz->intro, 'introformat' => FORMAT_HTML, 'timelimit' => 0,
    'attempts' => 0, 'attemptonlast' => 0, 'timeopen' => 0, 'timeclose' => 0, 'questionsperpage' => 0,
]);
sync_quiz_questions($course, $quiz, (int)$quizcm->id);
echo "QUESTIONS_SYNCED=5\nQUIZ_ATTEMPTS=unlimited\nQUIZ_TIMELIMIT=none\n";

echo "STEP=announcements\n";
$announcementcmid = put_course_announcement((int)$course->id, $announcementsubject);
rebuild_course_cache($course->id, true);
echo "ANNOUNCEMENT_CMID={$announcementcmid}\n";

echo "COURSE_ID={$course->id}\nQUIZ_CMID={$quizcm->id}\n";
$firstusername = $userprefix . str_pad('1', 4, '0', STR_PAD_LEFT);
$ok = authenticate_user_login($firstusername, $userpassword, false, $reason, false);
echo "LOGIN_TEST=" . ($ok ? 'ok' : 'fail') . "\nLOGIN_TEST_USER={$firstusername}\n";
$firstteacher = $teacherprefix . str_pad('1', 4, '0', STR_PAD_LEFT);
$tok = authenticate_user_login($firstteacher, $teacherpassword, false, $treason, false);
echo "TEACHER_LOGIN_TEST=" . ($tok ? 'ok' : 'fail') . "\nTEACHER_LOGIN_TEST_USER={$firstteacher}\n";
PHP

set +e
SEED_OUTPUT="$(
  kubectl -n "${NAMESPACE}" exec "${POD}" -c "${MOODLE_CONTAINER}" -- \
    runuser -u www-data -- php /tmp/seed_k6_auth_quiz.php \
      --userprefix="${USER_PREFIX}" --userpassword="${USER_PASSWORD}" --usercount="${USER_COUNT}" \
      --teacherprefix="${TEACHER_PREFIX}" --teacherpassword="${TEACHER_PASSWORD}" --teachercount="${TEACHER_COUNT}" \
      --courseshortname="${COURSE_SHORTNAME}" --coursefullname="${COURSE_FULLNAME}" \
      --quizname="${QUIZ_NAME}" --announcementsubject="${ANNOUNCEMENT_SUBJECT}" 2>&1
)"
SEED_RC=$?
set -e

if [[ ${SEED_RC} -ne 0 ]]; then echo "${SEED_OUTPUT}"; echo "Seed failed with exit code ${SEED_RC}."; exit ${SEED_RC}; fi
echo "${SEED_OUTPUT}"

COURSE_ID="$(printf '%s\n' "${SEED_OUTPUT}" | awk -F= '/^COURSE_ID=/{print $2}' | tail -n 1)"
QUIZ_CMID="$(printf '%s\n' "${SEED_OUTPUT}" | awk -F= '/^QUIZ_CMID=/{print $2}' | tail -n 1)"
ANNOUNCEMENT_CMID="$(printf '%s\n' "${SEED_OUTPUT}" | awk -F= '/^ANNOUNCEMENT_CMID=/{print $2}' | tail -n 1)"
LOGIN_TEST="$(printf '%s\n' "${SEED_OUTPUT}" | awk -F= '/^LOGIN_TEST=/{print $2}' | tail -n 1)"
TEACHER_LOGIN_TEST="$(printf '%s\n' "${SEED_OUTPUT}" | awk -F= '/^TEACHER_LOGIN_TEST=/{print $2}' | tail -n 1)"

if [[ -z "${COURSE_ID}" || -z "${QUIZ_CMID}" || -z "${ANNOUNCEMENT_CMID}" ]]; then echo "Seed failed: COURSE_ID/QUIZ_CMID/ANNOUNCEMENT_CMID not found in output."; exit 1; fi
if [[ "${LOGIN_TEST}" != "ok" || "${TEACHER_LOGIN_TEST}" != "ok" ]]; then echo "Seed failed: login test failed."; exit 1; fi

echo "Done."
echo "Announcement: /mod/forum/view.php?id=${ANNOUNCEMENT_CMID}"
echo "Run k6 (students only):"
echo "  PROFILE=auth_quiz QUIZ_PATH=/mod/quiz/view.php?id=${QUIZ_CMID} AUTH_USER_PREFIX=${USER_PREFIX} AUTH_USER_COUNT=${USER_COUNT} AUTH_USER_PASSWORD=${USER_PASSWORD} ./0_stress_testing.sh"
echo ""
echo "Run k6 (mixed students + teachers):"
echo "  PROFILE=mixed_roles QUIZ_PATH=/mod/quiz/view.php?id=${QUIZ_CMID} COURSE_PATH=/course/view.php?id=${COURSE_ID} AUTH_USER_PREFIX=${USER_PREFIX} AUTH_USER_COUNT=${USER_COUNT} AUTH_USER_PASSWORD=${USER_PASSWORD} TEACHER_USER_PREFIX=${TEACHER_PREFIX} TEACHER_USER_COUNT=${TEACHER_COUNT} TEACHER_USER_PASSWORD=${TEACHER_PASSWORD} TEACHER_RATIO_PCT=20 ./0_stress_testing.sh"
