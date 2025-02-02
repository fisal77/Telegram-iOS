import Foundation
import UIKit
import AsyncDisplayKit
import Display
import TelegramCore
import TelegramPresentationData

private func loadCountryCodes() -> [(String, Int)] {
    guard let filePath = frameworkBundle.path(forResource: "PhoneCountries", ofType: "txt") else {
        return []
    }
    guard let stringData = try? Data(contentsOf: URL(fileURLWithPath: filePath)) else {
        return []
    }
    guard let data = String(data: stringData, encoding: .utf8) else {
        return []
    }
    
    let delimiter = ";"
    let endOfLine = "\n"
    
    var result: [(String, Int)] = []
    
    var currentLocation = data.startIndex
    
    while true {
        guard let codeRange = data.range(of: delimiter, options: [], range: currentLocation ..< data.endIndex) else {
            break
        }
        
        let countryCode = String(data[currentLocation ..< codeRange.lowerBound])
        
        guard let idRange = data.range(of: delimiter, options: [], range: codeRange.upperBound ..< data.endIndex) else {
            break
        }
        
        let countryId = String(data[codeRange.upperBound ..< idRange.lowerBound])
        
        let maybeNameRange = data.range(of: endOfLine, options: [], range: idRange.upperBound ..< data.endIndex)
        
        if let countryCodeInt = Int(countryCode) {
            result.append((countryId, countryCodeInt))
        }
        
        if let maybeNameRange = maybeNameRange {
            currentLocation = maybeNameRange.upperBound
        } else {
            break
        }
    }
    
    return result
}

private let countryCodes: [(String, Int)] = loadCountryCodes()

func localizedContryNamesAndCodes(strings: PresentationStrings) -> [((String, String), String, Int)] {
    let locale = localeWithStrings(strings)
    var result: [((String, String), String, Int)] = []
    for (id, code) in countryCodes {
        if let englishCountryName = usEnglishLocale.localizedString(forRegionCode: id), let countryName = locale.localizedString(forRegionCode: id) {
            result.append(((englishCountryName, countryName), id, code))
        } else {
            assertionFailure()
        }
    }
    return result
}

final class AuthorizationSequenceCountrySelectionControllerNode: ASDisplayNode, UITableViewDelegate, UITableViewDataSource {
    let itemSelected: (((String, String), String, Int)) -> Void
    
    private let theme: PresentationTheme
    private let strings: PresentationStrings
    private let displayCodes: Bool
    private let needsSubtitle: Bool
    
    private let tableView: UITableView
    private let searchTableView: UITableView
    
    private let sections: [(String, [((String, String), String, Int)])]
    private let sectionTitles: [String]
    
    private var searchResults: [((String, String), String, Int)] = []
    
    init(theme: PresentationTheme, strings: PresentationStrings, displayCodes: Bool, itemSelected: @escaping (((String, String), String, Int)) -> Void) {
        self.theme = theme
        self.strings = strings
        self.displayCodes = displayCodes
        self.itemSelected = itemSelected
        
        self.needsSubtitle = strings.baseLanguageCode != "en"
        
        self.tableView = UITableView(frame: CGRect(), style: .plain)
        self.searchTableView = UITableView(frame: CGRect(), style: .plain)
        self.searchTableView.isHidden = true
        
        let countryNamesAndCodes = localizedContryNamesAndCodes(strings: strings)
        
        var sections: [(String, [((String, String), String, Int)])] = []
        for (names, id, code) in countryNamesAndCodes.sorted(by: { lhs, rhs in
            return lhs.0.1 < rhs.0.1
        }) {
            let title = String(names.1[names.1.startIndex ..< names.1.index(after: names.1.startIndex)]).uppercased()
            if sections.isEmpty || sections[sections.count - 1].0 != title {
                sections.append((title, []))
            }
            sections[sections.count - 1].1.append((names, id, code))
        }
        self.sections = sections
        var sectionTitles = sections.map { $0.0 }
        sectionTitles.insert(UITableViewIndexSearch, at: 0)
        self.sectionTitles = sectionTitles
        
        super.init()
        
        self.setViewBlock({
            return UITracingLayerView()
        })
        
        self.backgroundColor = theme.list.plainBackgroundColor
        
        self.tableView.backgroundColor = theme.list.plainBackgroundColor
        
        self.tableView.backgroundColor = self.theme.list.plainBackgroundColor
        self.tableView.separatorColor = self.theme.list.itemPlainSeparatorColor
        self.tableView.backgroundView = UIView()
        self.tableView.sectionIndexColor = self.theme.list.itemAccentColor
        
        self.searchTableView.backgroundColor = self.theme.list.plainBackgroundColor
        
        self.searchTableView.backgroundColor = self.theme.list.plainBackgroundColor
        self.searchTableView.separatorColor = self.theme.list.itemPlainSeparatorColor
        self.searchTableView.backgroundView = UIView()
        self.searchTableView.sectionIndexColor = self.theme.list.itemAccentColor
        
        self.tableView.delegate = self
        self.tableView.dataSource = self
        
        self.searchTableView.delegate = self
        self.searchTableView.dataSource = self
        
        self.view.addSubview(self.tableView)
        self.view.addSubview(self.searchTableView)
    }
    
    func containerLayoutUpdated(_ layout: ContainerViewLayout, navigationBarHeight: CGFloat, transition: ContainedViewLayoutTransition) {
        transition.updateFrame(view: self.tableView, frame: CGRect(origin: CGPoint(x: 0.0, y: navigationBarHeight), size: CGSize(width: layout.size.width, height: layout.size.height - navigationBarHeight)))
        transition.updateFrame(view: self.searchTableView, frame: CGRect(origin: CGPoint(x: 0.0, y: navigationBarHeight), size: CGSize(width: layout.size.width, height: layout.size.height - navigationBarHeight)))
    }
    
    func animateIn() {
        self.layer.animatePosition(from: CGPoint(x: self.layer.position.x, y: self.layer.position.y + self.layer.bounds.size.height), to: self.layer.position, duration: 0.5, timingFunction: kCAMediaTimingFunctionSpring)
    }
    
    func animateOut(completion: @escaping () -> Void) {
        self.layer.animatePosition(from: self.layer.position, to: CGPoint(x: self.layer.position.x, y: self.layer.position.y + self.layer.bounds.size.height), duration: 0.2, timingFunction: kCAMediaTimingFunctionEaseInEaseOut, removeOnCompletion: false, completion: { _ in
            completion()
        })
    }
    
    func updateSearchQuery(_ query: String) {
        if query.isEmpty {
            self.searchResults = []
            self.searchTableView.reloadData()
            self.searchTableView.isHidden = true
        } else {
            let normalizedQuery = query.lowercased().trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
            
            var results: [((String, String), String, Int)] = []
            for (_, items) in self.sections {
                for item in items {
                    if item.0.0.lowercased().hasPrefix(normalizedQuery) || item.0.1.lowercased().hasPrefix(normalizedQuery) {
                        results.append(item)
                    }
                }
            }
            
            self.searchResults = results
            self.searchTableView.isHidden = false
            self.searchTableView.reloadData()
        }
    }
    
    func numberOfSections(in tableView: UITableView) -> Int {
        if tableView === self.tableView {
            return self.sections.count
        } else {
            return 1
        }
    }
    
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        if tableView === self.tableView {
            return self.sections[section].1.count
        } else {
            return self.searchResults.count
        }
    }
    
    func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        if tableView === self.tableView {
            return self.sections[section].0
        } else {
            return nil
        }
    }
    
    func tableView(_ tableView: UITableView, willDisplayHeaderView view: UIView, forSection section: Int) {
        (view as? UITableViewHeaderFooterView)?.backgroundView?.backgroundColor = self.theme.list.plainBackgroundColor
        (view as? UITableViewHeaderFooterView)?.textLabel?.textColor = self.theme.list.itemPrimaryTextColor
    }
    
    func sectionIndexTitles(for tableView: UITableView) -> [String]? {
        if tableView === self.tableView {
            return self.sectionTitles
        } else {
            return nil
        }
    }
    
    func tableView(_ tableView: UITableView, sectionForSectionIndexTitle title: String, at index: Int) -> Int {
        if tableView === self.tableView {
            if index == 0 {
                return 0
            } else {
                return max(0, index - 1)
            }
        } else {
            return 0
        }
    }
    
    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell: UITableViewCell
        if let currentCell = tableView.dequeueReusableCell(withIdentifier: "CountryCell") {
            cell = currentCell
        } else {
            cell = UITableViewCell(style: self.needsSubtitle ? .subtitle : .default, reuseIdentifier: "CountryCell")
            let label = UILabel()
            label.font = Font.medium(17.0)
            cell.accessoryView = label
            cell.selectedBackgroundView = UIView()
        }
        
        let countryName: String
        let originalCountryName: String
        let code: String
        if tableView === self.tableView {
            countryName = self.sections[indexPath.section].1[indexPath.row].0.1
            originalCountryName = self.sections[indexPath.section].1[indexPath.row].0.0
            code = "+\(self.sections[indexPath.section].1[indexPath.row].2)"
        } else {
            countryName = self.searchResults[indexPath.row].0.1
            originalCountryName = self.searchResults[indexPath.row].0.0
            code = "+\(self.searchResults[indexPath.row].2)"
        }
        
        cell.textLabel?.text = countryName
        cell.detailTextLabel?.text = originalCountryName
        if self.displayCodes, let label = cell.accessoryView as? UILabel {
            label.text = code
            label.sizeToFit()
            label.textColor = self.theme.list.itemPrimaryTextColor
        }
        cell.textLabel?.textColor = self.theme.list.itemPrimaryTextColor
        cell.detailTextLabel?.textColor = self.theme.list.itemPrimaryTextColor
        cell.backgroundColor = self.theme.list.plainBackgroundColor
        cell.selectedBackgroundView?.backgroundColor = self.theme.list.itemHighlightedBackgroundColor
        return cell
    }
    
    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        if tableView === self.tableView {
            self.itemSelected(self.sections[indexPath.section].1[indexPath.row])
        } else {
            self.itemSelected(self.searchResults[indexPath.row])
        }
    }
    
    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        self.view.endEditing(true)
    }
}
