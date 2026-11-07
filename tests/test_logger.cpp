#include<pans/logger/log_line.h>

#include <cstdlib>
#include<filesystem>
#include<iostream>
#include<fstream>
#include<string_view>
using namespace std;

/*
int main(){
    const std::filesystem::path output_path = std::filesystem::temp_directory_path() / "test_logger.log";
    std::ofstream(output_path , std::ios::binary | std::ios::trunc);

    auto logger = std::make_shared<pans::Logger>("test");
    logger->addAppender(pans::MakeStdoutAppender());
    logger->addAppender(pans::MakeFileAppender(output_path.string()));


    PANS_LOG_DEBUG(logger) << "debug message";
    PANS_LOG_INFO(logger) << "info message";
    PANS_LOG_WARN(logger) << "warning message";
    PANS_LOG_ERROR(logger) << "error message";
    PANS_LOG_FATAL(logger) << "fatal message";
    std::cout << "----------------------------------------------------" << std::endl;
    PANS_LOG_FMT_DEBUG(logger, "debug message");
    PANS_LOG_FMT_INFO(logger, "info message");
    PANS_LOG_FMT_WARN(logger, "warn message");
    PANS_LOG_FMT_ERROR(logger, "error message");
    PANS_LOG_FMT_FATAL(logger, "fatal message");
    char c = 'a';
    int i = 42;
    const char msg1[] = "hello";
    const std::string msg2 = "world";
    const std::string_view msg3 = "pans 磐石";

    auto g_logger = logger;
    std::cout << "----------------------------------------------------" << std::endl;
    LOG_INFO << "c=" << c << " i=" << i << " msg1: " << msg1 << " msg2: " << msg2 << " msg3: " << msg3;
    PANS_LOG_FMT_INFO(logger, "c=%c i=%d msg1: %s msg2: %s msg3: %s", c, i, msg1, msg2.c_str(), msg3.data());

    logger->sync();
    std::cout << "\nThe same records were written to: " << output_path << '\n';

    return 0;
}
*/

int main(){
    const std::filesystem::path output_path = std::filesystem::temp_directory_path() / "test_logger.log";
    std::ofstream(output_path , std::ios::binary | std::ios::trunc);

    auto logger = std::make_shared<pans::Logger>("test");
    logger->addAppender(pans::MakeStdoutAppender());
    logger->addAppender(pans::MakeFileAppender(output_path.string()));
/*notes: pans::Logger 初始化步骤
1. 构造函数 ： Logger::Logger(std::string name):m_impl(std::make_unique<Impl>(std::move(name))){}
    => 构造Logger::Impl  => m_formatter = std::make_shared<const detail::Formatter>(DEFAULT_LOG_PATTERN); // 先整上默认值
2. const detail::Formatter构造函数   => Formatter::parse()  初始化 m_items
    注： m_items ： std::vector< std::unique_ptr<FormatItem>  > 
         LogLevel::Level::LOG_LV_DEBUG
3. 一个logger 含有一个 Formatter 
*/
/*notes: 
1. logger->addAppender(pans::MakeStdoutAppender()); => 
    会add 到这里面 std::vector<AppenderPtr> m_appenders;
*/

    PANS_LOG_DEBUG(logger) << "debug message ";
/*notes: 步骤：
1.PANS_LOG_DEBUG(logger) => 创建一个 LogLine 对象，其内部通过 Fast Pimpl（placement new）就地构造 Impl，采集时间戳、线程 ID、线程名等元数据。
    PANS_LOG_DEBUG(logger)<< "debug message "  
            =>  pans::detail::LogLine(*pans_log_logger , pans_log_level , __LINE__,__FILE__).stream()<< "debug message "
    Impl : 包含日志消息的缓冲区、时间戳、线程 ID、线程名等元数据。包含：  
                    InlineBuffer<LOG_MESSAGE_INLINE_CAPACITY>m_inlineBuffer;
                    SmallStreamBuffer<LOG_MESSAGE_INLINE_CAPACITY> m_streamBuffer;
                    std::ostream m_stream;
    日志消息的缓冲区: 用于存储实际的日志内容。LogLine(...).stream()<< "debug message " 将日志消息写入m_inlineBuffer中。
    m_inlineBuffer 中记录的是消息字符串
2. 通过 LogLine::getRecord() 返回 LogRecordView ： 
                                 LogLevel::Level m_level = LogLevel::Level::LOG_LV_DEBUG;
                                std::string_view m_loggerName = ""; // 日志器的名字, 可以有多个日志器'
                                std::string_view m_message = ""; // 日志内容
                                std::chrono::system_clock::time_point   m_timestamp; //时间戳
                                std::chrono::steady_clock::duration     m_elapsed;  //  启动服务器到现在多久 默认是 nanoseconds  纳秒                        
                                std::uint64_t m_threadId = 0;  // 线程ID
                                std::uint64_t m_fiberId  = 0;  // 协程ID 
                                std::string_view m_threadName = ""; // 线程名
                                std::string_view m_fileName = ""; // 文件名
                                std::uint64_t m_line = 0; // 文件名 + 行号 定位 
3. 日志消息在 LogLine 对象析构时 ，调用LoggerAccess::Submit(m_logger , getRecord()); =》 logger.m_impl->submit(record);
        =》m_formatter->format(record , formatted_record); =》Formatter::format( record , output)
        =》MessageFormatItem :: format(record , output); => output.append(...)
    注 ：output  FormattedRecordBuffer = InlineBuffer<FORMATTED_RECORD_INLINE_CAPACITY>; 
        formatted_record 类型 ：  FormattedRecordBuffer = InlineBuffer<FORMATTED_RECORD_INLINE_CAPACITY>;

4. 日志记录器根据配置的 Appender 将日志消息输出到相应的目标（如标准输出、文件等）。
        Append(appender , record.m_level , formatted_record.view()) =>(遍历logger的appender)=> appender->m_impl->append(level , formatted_record);
        =>  writeUnlocked(formatted_record); 
5. 日志记录器在析构或调用 sync() 时，会将缓冲区中的日志消息刷新到目标。
*/
    PANS_LOG_INFO(logger) << "info message";
    PANS_LOG_WARN(logger) << "warning message";
    PANS_LOG_ERROR(logger) << "error message";
    PANS_LOG_FATAL(logger) << "fatal message";
    std::cout << "----------------------------------------------------" << std::endl;
    PANS_LOG_FMT_DEBUG(logger, "debug message");
    std::cout<<std::endl;
    PANS_LOG_FMT_DEBUG(logger, "debug message%d , %f " , 10 , 3.333333333 );
/*notes: 
    PANS_LOG_FMT_DEBUG(logger, "debug message");=> LogPrintf(*pans_log_logger , pans_log_level , __LINE__, __FILE__, (format)__VA_OPT__(,) __VA_ARGS__)

    void LogPrintf(logger , level,  line,  file_name, format, ...)
        1. 先构造LogLine : LogLine log_line(logger, level, line, file_name);
        2. log_line.stream().write(inline_buffer.data() , static_cast<std::streamsize>(message_size));
            写入的地方是 LogLine 内部的 InLineBuffer，即 log_line.stream() 对应的缓冲区。
            这个缓冲区是栈上分配的，生命周期与 LogLine 对象一致。
        3. 析构时， 调用submit ，先转成 formatted_record ， 再写入到实际的日志目标（如文件、标准输出等）。
    */
    PANS_LOG_FMT_INFO(logger, "info message");
    PANS_LOG_FMT_WARN(logger, "warn message");
    PANS_LOG_FMT_ERROR(logger, "error message");
    PANS_LOG_FMT_FATAL(logger, "fatal message");
    char c = 'a';
    int i = 42;
    const char msg1[] = "hello";
    const std::string msg2 = "world";
    const std::string_view msg3 = "pans 磐石";

    auto g_logger = logger;
    std::cout << "----------------------------------------------------" << std::endl;
    LOG_INFO << "c=" << c << " i=" << i << " msg1: " << msg1 << " msg2: " << msg2 << " msg3: " << msg3;
    PANS_LOG_FMT_INFO(logger, "c=%c i=%d msg1: %s msg2: %s msg3: %s", c, i, msg1, msg2.c_str(), msg3.data());

    logger->sync();
    // std::cout << "\nThe same records were written to: " << output_path << '\n';

    return 0;
}